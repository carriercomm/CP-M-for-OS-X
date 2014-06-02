//
//  BDOS.m
//  CPM for OS X
//
//  Created by Thomas Harte on 12/09/2012.
//  Copyright (c) 2012 Thomas Harte. All rights reserved.
//

#import "BDOS.h"

#import "RAMModule.h"
#import "Processor.h"
#import "BIOS.h"
#import "FileControlBlock.h"

@implementation CPMBDOS
{
	/*
		The three things we need to connect in order to function
	*/
	CPMRAMModule *_memory;
	CPMProcessor *_processor;
	CPMBIOS *_bios;

	/*
		State for open files
	*/
	NSMutableDictionary *_fileHandlesByControlBlock;

	/*
		State for open drives
	*/
	uint8_t _currentDrive, _numberOfMappedDrives;
	NSMutableDictionary *_basePathsByDrive;

	/*
		State for ongoing file search
	*/
	NSEnumerator *_searchEnumerator;

	/*
		State for buffered console input
	*/
	BOOL _isPerformingConsoleInput;
	uint8_t _inputBufferSize, _inputBufferOffset;
	uint16_t _inputBufferAddress;

	/*
		General state
	*/
	uint16_t _dmaAddress;
}

#pragma mark -
#pragma mark Init; drive management

- (id)initWithContentsOfURL:(NSURL *)URL terminalView:(CPMTerminalView *)terminalView
{
	self = [super init];

	if(self)
	{
		// load the nominated executable
		NSData *data = [NSData dataWithContentsOfURL:URL];
		if(!data || !terminalView)
		{
			return nil;
		}

		// get base path for drive 0...
		_basePathsByDrive = [NSMutableDictionary dictionary];
		_basePathsByDrive[@1] = [[URL path] stringByDeletingLastPathComponent];
		_currentDrive = _numberOfMappedDrives = 1;

		// create memory, a CPU and a BIOS
		_memory = [[CPMRAMModule alloc] init];
		_processor = [[CPMProcessor alloc] initWithRAM:_memory];
		_bios = [[CPMBIOS alloc] initWithTerminalView:terminalView processor:_processor];

		// copy the executable into memory, set the initial program counter
		[_memory setData:data atAddress:0x100];
		_processor.programCounter = 0x100;

		// configure the bios trapping to occur as late as it can while
		// still having room for a full BIOS jump table
		uint16_t biosAddress = 65536-99;
		_processor.biosAddress = biosAddress;

		// we'll be the delegate, in order to trap all that stuff
		_processor.delegate = self;

		// setup the standard BIOS call
		[_memory setValue:0xc3 atAddress:0];
		[_memory setValue:(biosAddress+3)&0xff atAddress:1];
		[_memory setValue:(biosAddress+3) >> 8 atAddress:2];

		// set the call to perform BDOS functions to go to where the
		// BIOS theoretically starts — this is where the cold start
		// routine would go on a real CP/M machine and we're trying
		// to use the absolute minimal amount of memory possible
		[_memory setValue:0xc3 atAddress:5];
		[_memory setValue:biosAddress&0xff atAddress:6];
		[_memory setValue:biosAddress >> 8 atAddress:7];

		// set the top of the stack to be the address 0000 so that programs
		// that use return to exit function appropriately; also give SP a
		// sensible corresponding value
		[_memory setValue:0x00 atAddress:biosAddress-1];
		[_memory setValue:0x00 atAddress:biosAddress-2];
		_processor.spRegister = biosAddress-2;

		// the things pointed to beyond the BIOS address should all be jumps
		// to actual program code; some CP/M programs read the addresses and
		// use other means to get into the BIOS. So we need to set up appropriate
		// jump statments
		for(int c = biosAddress; c < 65536; c += 3)
		{
			[_memory setValue:0xc3 atAddress:(uint16_t)c];
			[_memory setValue:(uint8_t)(c&0xff) atAddress:(uint16_t)(c+1)];
			[_memory setValue:(uint8_t)(c >> 8) atAddress:(uint16_t)(c+2)];
		}

		// also set the default DMA address
		_dmaAddress = 0x80;

		// allocate a dictionary to keep track of our open files
		_fileHandlesByControlBlock = [[NSMutableDictionary alloc] init];
	}

	return self;
}

- (void)addAccessToURL:(NSURL *)URL
{
	NSString *basePath = [[URL path] stringByDeletingLastPathComponent];
	uint8_t driveNumber;

	NSArray *allKeys = [_basePathsByDrive allKeysForObject:basePath];
	if([allKeys count])
	{
		driveNumber = [allKeys[0] unsignedCharValue];
	}
	else
	{
		_numberOfMappedDrives++;
		driveNumber = _numberOfMappedDrives;
		_basePathsByDrive[@(_numberOfMappedDrives)] = basePath;
	}

	NSString *cpmPath = [NSString stringWithFormat:@"%c:%@", 'A' + driveNumber - 1, [URL lastPathComponent]];
	[_bios.terminalView addStringToInputQueue:cpmPath filterToASCII:YES];
}

#pragma mark -
#pragma mark Temporal Call-ins

- (void)runForTimeInterval:(NSTimeInterval)interval;
{
	[_processor runForTimeInterval:interval];
	
	// didBlock should return whether the processor called anything
	// that could block at any time, but for now we'll just report
	// whether it's blocked now
	_didBlock = _processor.isBlocked;
}

- (void)runForNumberOfInstructions:(NSUInteger)numberOfInstructions
{
	[_processor runForNumberOfInstructions:numberOfInstructions];

	// <comment as above>
	_didBlock = _processor.isBlocked;
}

#pragma mark -
#pragma mark CPMProcessorDelegate

- (CPMProcessorShouldBlock)processor:(CPMProcessor *)processor isMakingBDOSCall:(uint8_t)call parameter:(uint16_t)parameter
{
//		case 10:	/* buffered console input */					break;

	CPMProcessorShouldBlock shouldBlock = NO;

//	NSLog(@"BDOS %d", call);

	switch(call)
	{
		case 0:		shouldBlock = [self exitProgram];								break;
		case 1:		shouldBlock = [_bios readCharacterAndEcho];						break;
		case 2:		shouldBlock = [self writeConsoleOutput:parameter];				break;
		case 6:		shouldBlock = [self directConsoleIOWithParameter:parameter];	break;
		case 9:		shouldBlock = [self outputStringWithParameter:parameter];		break;

		case 10:	shouldBlock = [self inputStringWithParameter:parameter];		break;
		case 11:	shouldBlock = [self getConsoleStatus];							break;
		case 12:	shouldBlock = [self getVersionNumber];							break;
		case 13:	shouldBlock = [self resetAllDisks];								break;
		case 14:	shouldBlock = [self selectDiskWithParameter:parameter];			break;
		case 15:	shouldBlock = [self openFileWithParameter:parameter];			break;
		case 16:	shouldBlock = [self closeFileWithParameter:parameter];			break;
		case 17:	shouldBlock	= [self searchForFirstWithParameter:parameter];		break;
		case 18:	shouldBlock	= [self searchForNextWithParameter:parameter];		break;
		case 19:	shouldBlock = [self deleteFileWithParameter:parameter];			break;

		case 20:	shouldBlock = [self readNextRecordWithParameter:parameter];		break;
		case 21:	shouldBlock = [self writeNextRecordWithParameter:parameter];	break;
		case 25:	shouldBlock = [self getCurrentDrive];							break;
		case 26:	shouldBlock = [self setDMAAddressWithParameter:parameter];		break;

		case 32:	shouldBlock = [self getOrSetUserAreaWithParameter:parameter];	break;
		case 33:	shouldBlock = [self readRandomRecordWithParameter:parameter];	break;
		case 35:	shouldBlock = [self computeFileSizeWithParameter:parameter];	break;

		default:
			NSLog(@"!!UNIMPLEMENTED!! BDOS call %d with parameter %04x", call, parameter);
		break;
	}

	return shouldBlock;
}

- (CPMProcessorShouldBlock)processor:(CPMProcessor *)processor isMakingBIOSCall:(uint8_t)call
{
	// we've cheekily set up BIOS call 0 to be our BDOS entry point,
	// so we'll redirect BIOS call 0 manually
	if(!call)
	{
		return [self processor:processor isMakingBDOSCall:processor.bcRegister&0xff parameter:processor.deRegister];
	}

	return [_bios makeCall:call];
}

- (void)processorDidHalt:(CPMProcessor *)processor
{
	// this should prompt the user, probably, but for now it just lets me know
	NSLog(@"!!Processor did halt!!");
}

- (uint8_t)bcdFromValue:(NSInteger)value
{
	return (uint8_t)((value%10) + ((value / 10) << 4));
}

- (uint8_t)processor:(CPMProcessor *)processor valueForPort:(uint8_t)port
{
	NSLog(@"IN A, ($%02x)", port);

	// the only ports currently implemented are those for the Kenmore real-time clock
	switch(port)
	{
		default: return 0xff;

		case 0xe2: return [self bcdFromValue:[[NSCalendar currentCalendar] components:NSCalendarUnitSecond fromDate:[NSDate date]].second];
		case 0xe3: return [self bcdFromValue:[[NSCalendar currentCalendar] components:NSCalendarUnitMinute fromDate:[NSDate date]].minute];
		case 0xe4: return [self bcdFromValue:[[NSCalendar currentCalendar] components:NSCalendarUnitHour fromDate:[NSDate date]].hour];
		case 0xe5: return [self bcdFromValue:[[NSCalendar currentCalendar] components:NSCalendarUnitWeekday fromDate:[NSDate date]].weekday];
		case 0xe6: return [self bcdFromValue:[[NSCalendar currentCalendar] components:NSCalendarUnitDay fromDate:[NSDate date]].day];
		case 0xe7: return [self bcdFromValue:[[NSCalendar currentCalendar] components:NSCalendarUnitMonth fromDate:[NSDate date]].month];
	}
}

#pragma mark -
#pragma mark Environment Management

- (BOOL)getVersionNumber
{
	// the high part is OS type (CP/M) and the low part is the BCD version number (2.2)
	[_processor set16bitCPMResult:0x0022];

	return NO;
}

- (BOOL)exitProgram
{
	NSLog(@"Program did exit");
	return YES;
}

#pragma mark -
#pragma mark Basic File IO setters and getters

- (BOOL)resetAllDisks
{
	_dmaAddress = 0x80;
	_currentDrive = 1;
	[_processor set8bitCPMResult:0];
	return NO;
}

- (BOOL)selectDiskWithParameter:(uint16_t)parameter
{
	// does the disk exist?
	if(_basePathsByDrive[@(parameter+1)])
	{
		_currentDrive = (parameter&0xff)+1;
		[_processor set8bitCPMResult:0];
	}
	else
	{
		[_processor set8bitCPMResult:0xff];
	}

	return NO;
}

- (BOOL)getCurrentDrive
{
	[_processor set8bitCPMResult:_currentDrive-1];
	return NO;
}

- (BOOL)setDMAAddressWithParameter:(uint16_t)parameter
{
	_dmaAddress = parameter;
	return NO;
}

#pragma mark -
#pragma mark File Helpers

- (CPMFileControlBlock *)fileControlBlockWithParameter:(uint16_t)parameter
{
	return [[CPMFileControlBlock alloc] initWithAddress:parameter inMemory:_memory];
}

#pragma mark -
#pragma mark File Search

- (NSString *)basePathForFileControlBlock:(CPMFileControlBlock *)fileControlBlock
{
	return _basePathsByDrive[@(fileControlBlock.drive ? fileControlBlock.drive : _currentDrive)];
}

- (BOOL)searchForFirstWithParameter:(uint16_t)parameter
{
	_searchEnumerator = nil;

	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];
	NSString *basePath = [self basePathForFileControlBlock:fileControlBlock];

	if(!basePath)
	{
		[_processor set8bitCPMResult:0xff];
	}
	else
	{
		[_processor set8bitCPMResult:0];

		NSError *error = nil;
		NSArray *allFilesInPath = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:&error];

		NSArray *matchingFiles = [allFilesInPath filteredArrayUsingPredicate:fileControlBlock.matchesPredicate];
		NSLog(@"%@ versus %@ begat %@", allFilesInPath, fileControlBlock, matchingFiles);

		_searchEnumerator = [matchingFiles objectEnumerator];
		return [self searchForNextWithParameter:parameter];
	}

	return NO;
}

- (BOOL)searchForNextWithParameter:(uint16_t)parameter
{
	NSString *nextFileName = [_searchEnumerator nextObject];
	if(!nextFileName)
	{
		[_processor set8bitCPMResult:0xff];
		_searchEnumerator = nil;
		return NO;
	}

	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:_dmaAddress];
	fileControlBlock.nameWithExtension = nextFileName;
	[_processor set8bitCPMResult:0];
	return NO;
}

#pragma mark -
#pragma mark File Open and Close

- (NSString *)fullPathForFileControlBlock:(CPMFileControlBlock *)fileControlBlock
{
	NSString *filename = [fileControlBlock nameWithExtension];
	NSString *basePath = [self basePathForFileControlBlock:fileControlBlock];
	if(basePath)
	{
		filename = [basePath stringByAppendingPathComponent:filename];
	}
	return filename;
}

- (BOOL)openFileWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];

	NSError *error = nil;

	NSString *fullPath = [self fullPathForFileControlBlock:fileControlBlock];
	NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:fullPath];

	if(handle && !error)
	{
		NSLog(@"Opened %@ for record %04x", fileControlBlock, parameter);

		[_processor set8bitCPMResult:0];
		_fileHandlesByControlBlock[fileControlBlock] = handle;
	}
	else
	{
		NSLog(@"Failed to open %@", fileControlBlock);
		[_processor set8bitCPMResult:0xff];
	}

	return NO;
}

- (BOOL)closeFileWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];

	NSLog(@"Closing %@", fileControlBlock);
	[_fileHandlesByControlBlock removeObjectForKey:fileControlBlock];
	[_processor set8bitCPMResult:0];

	return NO;
}

#pragma mark -
#pragma mark File Delete

- (BOOL)deleteFileWithParameter:(uint16_t)parameter
{
	NSLog(@"!!UNIMPLEMENTED!! should delete %@", [self fileControlBlockWithParameter:parameter]);

	// pretend we succeeded
	[_processor set8bitCPMResult:0];

	return NO;
}

#pragma mark -
#pragma mark File Read and Write

- (BOOL)writeNextRecordWithParameter:(uint16_t)parameter
{
	NSLog(@"!!UNIMPLEMENTED!! should write next record to %@", [self fileControlBlockWithParameter:parameter]);

	// pretend we succeeded
	[_processor set8bitCPMResult:0];

	return NO;
}

- (BOOL)readNextRecordWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];
	NSFileHandle *fileHandle = _fileHandlesByControlBlock[fileControlBlock];

	[fileHandle seekToFileOffset:fileControlBlock.linearFileOffset];
	NSData *nextRecord = [fileHandle readDataOfLength:128];
	if([nextRecord length])
	{
		[_memory setData:nextRecord atAddress:_dmaAddress];

		// sequential reads update the FCB
		fileControlBlock.linearFileOffset += 128;

		// report success
		[_processor set8bitCPMResult:0];
	}
	else
	{
		// set 0xff - end of file
		[_processor set8bitCPMResult:0xff];
	}

//	NSLog(@"did read sequential record for %@, offset %zd, DMA address %04x", fileControlBlock, fileControlBlock.linearFileOffset, _dmaAddress);

	return NO;
}

- (BOOL)readRandomRecordWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];
	NSFileHandle *fileHandle = _fileHandlesByControlBlock[fileControlBlock];
	
	[fileHandle seekToFileOffset:fileControlBlock.randomFileOffset];
	NSData *nextRecord = [fileHandle readDataOfLength:128];

	if([nextRecord length])
	{
		[_memory setData:nextRecord atAddress:_dmaAddress];

		// report success
		[_processor set8bitCPMResult:0];
	}
	else
	{
		// set error 6 - record number out of range
		[_processor set8bitCPMResult:0x06];
	}

//	NSLog(@"did read random record for %@, offset %zd, DMA address %04x", fileControlBlock, fileControlBlock.randomFileOffset, _dmaAddress);

	return NO;
}

- (BOOL)computeFileSizeWithParameter:(uint16_t)parameter
{
	CPMFileControlBlock *fileControlBlock = [self fileControlBlockWithParameter:parameter];
	NSString *fullPath = [self fullPathForFileControlBlock:fileControlBlock];

	NSError *error;
	NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:&error];

	if(error)
	{
		[_processor set8bitCPMResult:0xff];
	}
	else
	{
		[_processor set8bitCPMResult:0];
		size_t size = [fileAttributes[NSFileSize] unsignedIntegerValue];
		fileControlBlock.randomFileOffset = size >> 7;
	}

//	NSLog(@"did compute size of random record for %@, size %zd", fileControlBlock, fileControlBlock.randomFileOffset);

	return NO;
}

#pragma mark -
#pragma mark User Area Manipulation

- (BOOL)getOrSetUserAreaWithParameter:(uint16_t)parameter
{
	if((parameter&0xff) == 0xff)
	{
		// we're always in area 0
		[_processor set8bitCPMResult:0];
	}
	else
	{
		// we don't support additional user areas
	}

	return NO;
}

#pragma mark -
#pragma mark Console IO

- (BOOL)directConsoleIOWithParameter:(uint16_t)parameter
{
	switch(parameter&0xff)
	{
		case 0xff:
			[_processor set8bitCPMResult:[_bios dequeueCharacterIfAvailable]];
		break;
		case 0xfe: return [self getConsoleStatus];
		default:
			[_bios writeConsoleOutput:parameter&0xff];
		break;
	}

	return NO;
}

- (BOOL)getConsoleStatus
{
	[_processor set8bitCPMResult:[_bios consoleStatus]];
	return NO;
}

- (BOOL)outputStringWithParameter:(uint16_t)parameter
{
	while(1)
	{
		uint8_t nextCharacter = [_memory valueAtAddress:parameter];
		if(nextCharacter == '$') break;
		[_bios writeConsoleOutput:nextCharacter];
		parameter++;
	}
	return NO;
}

- (BOOL)inputStringWithParameter:(uint16_t)parameter
{
	// figure out the buffer address
	if(parameter)
	{
		_inputBufferAddress = parameter;
		_inputBufferOffset = 0;
	}
	else
	{
		_inputBufferAddress = _dmaAddress;
		_inputBufferOffset = [_memory valueAtAddress:_inputBufferAddress+1];
	}
	_inputBufferSize = [_memory valueAtAddress:_inputBufferAddress];

	_isPerformingConsoleInput = YES;
	[self performMoreConsoleInput];

	return YES;
}

- (void)performMoreConsoleInput
{
	uint8_t nextChar;
	while((nextChar = [_bios dequeueCharacterIfAvailable]))
	{
		// terminate if we've hit any sort of newline or
		// carriage return
		if((nextChar == '\r') || (nextChar == '\n'))
		{
			_isPerformingConsoleInput = NO;
			[_processor unblock];
			return;
		}

		// check for backspace
		if(nextChar == '\b' || nextChar == '\x7f')
		{
			if(_inputBufferOffset)
			{
				_inputBufferOffset--;

				[_bios writeConsoleOutput:'\b'];
				[_bios writeConsoleOutput:' '];
				[_bios writeConsoleOutput:'\b'];
			}
		}
		else
		{
			// otherwise echo the thing and deposit it
			// in memory as requested
			[_bios writeConsoleOutput:nextChar];

			if(_inputBufferOffset < _inputBufferSize)
			{
				[_memory setValue:nextChar atAddress:(uint16_t)(_inputBufferAddress + _inputBufferOffset + 2)];
				_inputBufferOffset++;
			}
		}

		// write out the new string length
		[_memory setValue:_inputBufferOffset atAddress:_inputBufferAddress+1];
	}
}

- (BOOL)writeConsoleOutput:(uint16_t)character
{
	[_bios writeConsoleOutput:character&0xff];
	return NO;
}

#pragma mark -
#pragma mark CPMTerminalViewDelegate

- (void)terminalViewDidAddCharactersToBuffer:(CPMTerminalView *)terminalView
{
	[_bios terminalViewDidAddCharactersToBuffer:terminalView];

	if(_isPerformingConsoleInput)
		[self performMoreConsoleInput];
}

@end
