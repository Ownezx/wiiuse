/*
 *  wiiuse
 *
 *  Written By:
 *    Michael Laforest  < para >
 *    Email: < thepara (--AT--) g m a i l [--DOT--] com >
 *
 *  Copyright 2006-2007
 *
 *  This file is part of wiiuse.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *  $Header$
 *
 */

/**
 *  @file
 *  @brief Handles device I/O for Mac OS X.
 */

#ifdef __APPLE__

#import "os_mac.h"
#import "../events.h"

#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetoothUtilities.h>
#import <IOBluetooth/objc/IOBluetoothHostController.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Private IOBluetooth selectors needed for legacy PIN pairing. */
@interface IOBluetoothDevice (WiiusePairingPrivate)
- (id)classicPeer;
@end

@interface IOBluetoothDevicePair (WiiusePairingPrivate)
- (void)setUserDefinedPincode:(BOOL)enabled;
- (NSUInteger)currentPairingType;
@end

@interface NSObject (WiiusePairingCoordinatorPrivate)
+ (id)sharedInstance;
- (void)pairPeer:(id)peer forType:(NSUInteger)type withKey:(NSNumber *)key;
@end

@interface WiiuseWiimote (PrivateCallbacks)
- (void)handleHIDDeviceMatch:(IOHIDDeviceRef)hid;
- (void)handleHIDDeviceRemoval:(IOHIDDeviceRef)hid;
- (void)handleInputReport:(const uint8_t *)report length:(CFIndex)length;
@end

@interface WiiuseReceivedData (WiiuseQueuePolicy)
- (uint8_t)reportID;
- (BOOL)isStreamingReport;
@end

static void WiiuseHIDDeviceMatched(void *context,
								   IOReturn result,
								   void *sender,
								   IOHIDDeviceRef hid) {
	(void)sender;
	if (context && hid && result == kIOReturnSuccess) {
		[(WiiuseWiimote *)context handleHIDDeviceMatch:hid];
	}
}

static void WiiuseHIDDeviceRemoved(void *context,
								   IOReturn result,
								   void *sender,
								   IOHIDDeviceRef hid) {
	(void)sender;
	if (context && hid && result == kIOReturnSuccess) {
		[(WiiuseWiimote *)context handleHIDDeviceRemoval:hid];
	}
}

static void WiiuseHIDInputReport(void *context,
								 IOReturn result,
								 void *sender,
								 IOHIDReportType type,
								 uint32_t reportID,
								 uint8_t *report,
								 CFIndex reportLength) {
	(void)sender;
	(void)reportID;
	if (context && report && reportLength > 0 &&
		result == kIOReturnSuccess && type == kIOHIDReportTypeInput) {
		[(WiiuseWiimote *)context handleInputReport:report length:reportLength];
	}
}

/* Build a VID/PID matching array for the original and newer Nintendo remotes. */
static CFDictionaryRef WiiuseCreateHIDMatch(int productID) {
	int vendorID = 0x057e;
	CFNumberRef vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendorID);
	CFNumberRef product = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &productID);
	if (!vendor || !product) {
		if (vendor) CFRelease(vendor);
		if (product) CFRelease(product);
		return NULL;
	}

	const void *keys[] = { CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey) };
	const void *values[] = { vendor, product };
	CFDictionaryRef dictionary = CFDictionaryCreate(
		kCFAllocatorDefault,
		keys,
		values,
		2,
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks
	);
	CFRelease(vendor);
	CFRelease(product);
	return dictionary;
}

@implementation WiiuseWiimote

- (id)initWithPtr:(wiimote *)wm_ device:(IOBluetoothDevice *)device_ {
	self = [super init];
	if (self) {
		wm = wm_;
		device = [device_ retain];
		pairingAgent = nil;
		coreBluetoothManager = nil;
		hidManager = NULL;
		hidDevice = NULL;
		inputReportBuffer = NULL;
		inputReportBufferSize = 64;
		pairingFinished = NO;
		pairingError = kIOReturnNotReady;
		hidReady = NO;
		receivedData = [[NSMutableArray alloc] initWithCapacity:8];
		receivedDataLock = [[NSLock alloc] init];

		/* This also initialises the XPC path used by the private pairing API. */
		coreBluetoothManager = [[CBCentralManager alloc] initWithDelegate:nil queue:nil];
	}
	return self;
}

- (void)dealloc {
	[self disconnect];
	wm = NULL;
	[device release];
	device = nil;
	[pairingAgent release];
	pairingAgent = nil;
	[coreBluetoothManager release];
	coreBluetoothManager = nil;
	[receivedData release];
	[receivedDataLock release];
	[super dealloc];
}

#pragma mark - HID manager lifecycle

- (IOReturn)startHIDManager {
	if (hidManager) return kIOReturnSuccess;

	hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	if (!hidManager) {
		WIIUSE_ERROR("Unable to create IOHIDManager [id %i].", wm ? wm->unid : -1);
		return kIOReturnNoMemory;
	}

	CFDictionaryRef original = WiiuseCreateHIDMatch(0x0306); /* RVL-CNT-01 */
	CFDictionaryRef plus = WiiuseCreateHIDMatch(0x0330);     /* RVL-CNT-01-TR */
	if (!original || !plus) {
		if (original) CFRelease(original);
		if (plus) CFRelease(plus);
		CFRelease(hidManager);
		hidManager = NULL;
		return kIOReturnNoMemory;
	}

	const void *matches[] = { original, plus };
	CFArrayRef matchingArray = CFArrayCreate(
		kCFAllocatorDefault, matches, 2, &kCFTypeArrayCallBacks
	);
	CFRelease(original);
	CFRelease(plus);
	if (!matchingArray) {
		CFRelease(hidManager);
		hidManager = NULL;
		return kIOReturnNoMemory;
	}

	IOHIDManagerSetDeviceMatchingMultiple(hidManager, matchingArray);
	CFRelease(matchingArray);

	IOHIDManagerRegisterDeviceMatchingCallback(
		hidManager, WiiuseHIDDeviceMatched, self
	);
	IOHIDManagerRegisterDeviceRemovalCallback(
		hidManager, WiiuseHIDDeviceRemoved, self
	);
	IOHIDManagerScheduleWithRunLoop(
		hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode
	);

	IOReturn status = IOHIDManagerOpen(hidManager, kIOHIDOptionsTypeNone);
	if (status != kIOReturnSuccess) {
		WIIUSE_ERROR("IOHIDManagerOpen failed [id %i], IOReturn=0x%08x.",
					 wm ? wm->unid : -1, (unsigned int)status);
		IOHIDManagerUnscheduleFromRunLoop(
			hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode
		);
		CFRelease(hidManager);
		hidManager = NULL;
	}
	return status;
}

- (void)stopHIDManager {
	if (hidDevice) {
		IOHIDDeviceClose(hidDevice, kIOHIDOptionsTypeNone);
		CFRelease(hidDevice);
		hidDevice = NULL;
	}
	if (inputReportBuffer) {
		free(inputReportBuffer);
		inputReportBuffer = NULL;
	}
	hidReady = NO;

	if (hidManager) {
		IOHIDManagerUnscheduleFromRunLoop(
			hidManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode
		);
		IOHIDManagerClose(hidManager, kIOHIDOptionsTypeNone);
		CFRelease(hidManager);
		hidManager = NULL;
	}
}

- (void)handleHIDDeviceMatch:(IOHIDDeviceRef)hid {
	/* This backend intentionally attaches one Wii Remote per wiiuse instance. */
	if (hidDevice || !hid) return;

	IOReturn status = IOHIDDeviceOpen(hid, kIOHIDOptionsTypeNone);
	if (status != kIOReturnSuccess) {
		WIIUSE_ERROR("IOHIDDeviceOpen failed [id %i], IOReturn=0x%08x.",
					 wm ? wm->unid : -1, (unsigned int)status);
		return;
	}

	hidDevice = (IOHIDDeviceRef)CFRetain(hid);
	inputReportBuffer = (uint8_t *)calloc((size_t)inputReportBufferSize, sizeof(uint8_t));
	if (!inputReportBuffer) {
		WIIUSE_ERROR("Unable to allocate HID input buffer [id %i].", wm ? wm->unid : -1);
		IOHIDDeviceClose(hidDevice, kIOHIDOptionsTypeNone);
		CFRelease(hidDevice);
		hidDevice = NULL;
		return;
	}

	IOHIDDeviceRegisterInputReportCallback(
		hidDevice,
		inputReportBuffer,
		inputReportBufferSize,
		WiiuseHIDInputReport,
		self
	);
	hidReady = YES;
	WIIUSE_INFO("macOS HID device opened [id %i].", wm ? wm->unid : -1);
}

- (void)handleHIDDeviceRemoval:(IOHIDDeviceRef)hid {
	if (hidDevice && hid == hidDevice) {
		WiiuseDisconnectionMessage *message = [[WiiuseDisconnectionMessage alloc] init];
		[receivedDataLock lock];
		[receivedData addObject:message];
		[receivedDataLock unlock];
		[message release];
	}
}

- (void)handleInputReport:(const uint8_t *)report length:(CFIndex)length {
	if (!report || length <= 0) return;
	WiiuseReceivedData *message = [[WiiuseReceivedData alloc]
		initWithBytes:(void *)report length:(NSUInteger)length];
	if (!message) return;

	[receivedDataLock lock];

	/* Coalesce queued streaming reports, but retain protocol responses in order. */
	if ([message isStreamingReport]) {
		const uint8_t reportID = [message reportID];
		for (NSInteger i = (NSInteger)[receivedData count] - 1; i >= 0; --i) {
			id queued = [receivedData objectAtIndex:(NSUInteger)i];
			if ([queued isKindOfClass:[WiiuseReceivedData class]]) {
				WiiuseReceivedData *queuedReport = (WiiuseReceivedData *)queued;
				if ([queuedReport isStreamingReport] &&
					[queuedReport reportID] == reportID) {
					[receivedData removeObjectAtIndex:(NSUInteger)i];
				}
			}
		}
	}

	[receivedData addObject:message];
	[receivedDataLock unlock];
	[message release];
}

#pragma mark - Pairing

- (void)devicePairingPINCodeRequest:(id)sender {
	IOBluetoothDevicePair *pair = (IOBluetoothDevicePair *)sender;
	IOBluetoothDevice *pairDevice = [pair device];
	IOBluetoothHostController *host = [IOBluetoothHostController defaultController];
	NSString *hostAddress = [host addressAsString];

	if (!pairDevice || !hostAddress) {
		WIIUSE_ERROR("Cannot calculate Wii Remote pairing PIN [id %i].", wm ? wm->unid : -1);
		return;
	}

	BluetoothDeviceAddress hostAddressBytes;
	memset(&hostAddressBytes, 0, sizeof(hostAddressBytes));
	IOReturn parseStatus = IOBluetoothNSStringToDeviceAddress(hostAddress, &hostAddressBytes);
	if (parseStatus != kIOReturnSuccess) {
		WIIUSE_ERROR("Cannot parse host Bluetooth address [id %i].", wm ? wm->unid : -1);
		return;
	}

	/* Wii Remote legacy PIN: the host Bluetooth address in reverse byte order. */
	uint8_t pinBytes[8] = {
		hostAddressBytes.data[5], hostAddressBytes.data[4],
		hostAddressBytes.data[3], hostAddressBytes.data[2],
		hostAddressBytes.data[1], hostAddressBytes.data[0], 0, 0
	};
	uint64_t pinValue = 0;
	memcpy(&pinValue, pinBytes, sizeof(pinValue));

	/* Resolve the private class dynamically to avoid a hard link against a
	   private IOBluetooth class symbol that Apple may hide or rename. */
	Class coordinatorClass = NSClassFromString(@"IOBluetoothCoreBluetoothCoordinator");
	id coordinator = [coordinatorClass sharedInstance];
	id peer = [pairDevice classicPeer];
	if (!coordinator || !peer) {
		WIIUSE_ERROR("Pairing coordinator or classic peer unavailable [id %i].",
					 wm ? wm->unid : -1);
		return;
	}

	[coordinator pairPeer:peer
				  forType:[pair currentPairingType]
				  withKey:[NSNumber numberWithUnsignedLongLong:pinValue]];
	WIIUSE_DEBUG("Submitted legacy Wii Remote PIN to macOS pairing coordinator [id %i].",
				 wm ? wm->unid : -1);
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
	(void)sender;
	pairingError = error;
	pairingFinished = YES;
	if (error == kIOReturnSuccess) {
		WIIUSE_INFO("Bluetooth pairing completed [id %i].", wm ? wm->unid : -1);
	} else {
		WIIUSE_ERROR("Bluetooth pairing failed [id %i], IOReturn=0x%08x.",
					 wm ? wm->unid : -1, (unsigned int)error);
	}
}

- (IOReturn)connect {
	if (!device) {
		WIIUSE_ERROR("Missing Bluetooth device [id %i].", wm ? wm->unid : -1);
		return kIOReturnBadArgument;
	}

	IOReturn status = [self startHIDManager];
	if (status != kIOReturnSuccess) return status;

	NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
	if (![device isPaired]) {
		pairingFinished = NO;
		pairingError = kIOReturnNotReady;
		pairingAgent = [[IOBluetoothDevicePair pairWithDevice:device] retain];
		if (!pairingAgent) {
			WIIUSE_ERROR("Unable to allocate IOBluetoothDevicePair [id %i].", wm ? wm->unid : -1);
			[self stopHIDManager];
			return kIOReturnNoMemory;
		}

		[pairingAgent setDelegate:self];
		[pairingAgent setUserDefinedPincode:YES];
		status = [pairingAgent start];
		if (status != kIOReturnSuccess) {
			WIIUSE_ERROR("Unable to start Bluetooth pairing [id %i], IOReturn=0x%08x.",
						 wm ? wm->unid : -1, (unsigned int)status);
			[pairingAgent setDelegate:nil];
			[pairingAgent release];
			pairingAgent = nil;
			[self stopHIDManager];
			return status;
		}

		/* Pairing callbacks and IOHID matching callbacks are delivered on this run loop. */
		NSDate *pairDeadline = [NSDate dateWithTimeIntervalSinceNow:25.0];
		while (!pairingFinished && [pairDeadline timeIntervalSinceNow] > 0) {
			NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:0.1];
			[runLoop runMode:NSDefaultRunLoopMode beforeDate:tick];
		}

		if (!pairingFinished) {
			WIIUSE_ERROR("Timed out waiting for Bluetooth pairing [id %i].", wm ? wm->unid : -1);
			[self disconnect];
			return kIOReturnTimeout;
		}
		if (pairingError != kIOReturnSuccess) {
			status = pairingError;
			[self disconnect];
			return status;
		}
	} else {
		WIIUSE_INFO("Wii Remote is already paired; skipping PIN pairing [id %i].",
					wm ? wm->unid : -1);
	}


	if (![device isConnected]) {
		IOReturn connectionStatus = [device openConnection];
		if (connectionStatus != kIOReturnSuccess) {
			WIIUSE_WARNING("openConnection after pairing returned 0x%08x [id %i]; waiting for HID.",
						   (unsigned int)connectionStatus, wm ? wm->unid : -1);
		}
	}

	NSDate *hidDeadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
	while (!hidReady && [hidDeadline timeIntervalSinceNow] > 0) {
		NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:0.1];
		[runLoop runMode:NSDefaultRunLoopMode beforeDate:tick];
	}

	if (!hidReady || !hidDevice) {
		WIIUSE_ERROR("Pairing succeeded but macOS did not expose a Wii Remote HID device [id %i].",
					 wm ? wm->unid : -1);
		[self disconnect];
		return kIOReturnNotFound;
	}

	WIIUSE_INFO("Wii Remote connected through macOS HID [id %i].", wm ? wm->unid : -1);
	return kIOReturnSuccess;
}

- (void)disconnect {
	[self stopHIDManager];

	if (pairingAgent) {
		[pairingAgent setDelegate:nil];
		[pairingAgent stop];
		[pairingAgent release];
		pairingAgent = nil;
	}

	if (device && [device isConnected]) {
		[device closeConnection];
	}

	pairingFinished = NO;
	pairingError = kIOReturnNotReady;
}

#pragma mark read, write

- (int) checkForAvailableDataForBuffer: (byte*) buffer length: (NSUInteger) bufferLength {
	int result = -1;

	[receivedDataLock lock];
	if([receivedData count]) {
		// look at first item in queue
		NSObject<WiiuseReceivedMessage>* firstMessage = [receivedData objectAtIndex:0];
		result = [firstMessage applyToStruct:wm buffer: buffer length: bufferLength];
		if(result >= 0)
			[receivedData removeObjectAtIndex:0];
	}
	[receivedDataLock unlock];

	return result;
}

- (void) waitForIncomingData: (NSTimeInterval) duration {
	NSDate* timeoutDate = [NSDate dateWithTimeIntervalSinceNow: duration];
	NSRunLoop *theRL = [NSRunLoop currentRunLoop];
	while (true) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init]; // This is used for fast release of NSDate, otherwise it leaks
		if(![theRL runMode:NSDefaultRunLoopMode beforeDate:timeoutDate]) {
			WIIUSE_ERROR("Could not start run loop while waiting for read [id %i].", wm->unid);
			break;
		}
		[pool drain];

		[receivedDataLock lock];
		NSUInteger count = [receivedData count];
		[receivedDataLock unlock];
		if(count) {
			// received some data, stop waiting
			break;
		}

		if([timeoutDate isLessThanOrEqualTo:[NSDate date]]) {
			// timeout
			break;
		}
	}
}

// result = length of data copied to event buffer
- (int) readBuffer:(byte *)buffer length:(NSUInteger)bufferLength {
	// is there already some data to read?
	int result = [self checkForAvailableDataForBuffer: buffer length: bufferLength];
	if(result < 0) {
		// wait a short amount of time, until data becomes available or a timeout is reached
		[self waitForIncomingData:0.05];

		// check again
		result = [self checkForAvailableDataForBuffer: buffer length: bufferLength];
	}

	return result >= 0 ? result : 0;
}

- (int)writeReport:(byte)report_type buffer:(byte *)buffer length:(NSUInteger)length {
	if (!hidDevice) {
		WIIUSE_ERROR("Attempted to write without an open HID device [id %i].", wm ? wm->unid : -1);
		return 0;
	}
	if (length + 1 > (NSUInteger)MAX_PAYLOAD) {
		WIIUSE_ERROR("HID output report is too large [id %i].", wm ? wm->unid : -1);
		return 0;
	}

	uint8_t report[MAX_PAYLOAD];
	report[0] = report_type;
	if (length > 0) memcpy(report + 1, buffer, length);

	/* Include the report ID in the first byte, as required by IOHIDDeviceSetReport. */
	IOReturn status = IOHIDDeviceSetReport(
		hidDevice,
		kIOHIDReportTypeOutput,
		report_type,
		report,
		(CFIndex)(length + 1)
	);
	if (status != kIOReturnSuccess) {
		WIIUSE_ERROR("IOHIDDeviceSetReport failed [id %i], report=0x%02x, IOReturn=0x%08x.",
					 wm ? wm->unid : -1, report_type, (unsigned int)status);
		return 0;
	}
	return (int)length;
}

@end

#pragma mark WiiuseReceivedMessage

@implementation WiiuseReceivedData

- (id) initWithData:(NSData *)data_ {
	self = [super init];
	if (self) {
		data = [data_ retain];
	}
	return self;
}
- (id) initWithBytes: (void*) bytes length: (NSUInteger) length {
	NSData* data_ = [[NSData alloc] initWithBytes:bytes length:length];
	id result = [self initWithData: data_];
	[data_ release];
	return result;
}

- (uint8_t)reportID {
	if(!data || [data length] == 0) return 0;
	return ((const uint8_t*)[data bytes])[0];
}

- (BOOL)isStreamingReport {
	uint8_t reportID_ = [self reportID];
	return (reportID_ >= 0x30 && reportID_ <= 0x37) ||
		reportID_ == 0x3d || reportID_ == 0x3e || reportID_ == 0x3f;
}

- (void) dealloc {
	[data release];
	[super dealloc];
}

- (int) applyToStruct:(wiimote *)wm buffer:(byte *)buffer length:(NSUInteger)bufferLength {
	byte* bytes = (byte*) [data bytes];
	NSUInteger length = [data length];
	if(length > bufferLength) {
		WIIUSE_WARNING("Received data was longer than event buffer. Dropping excess bytes.");
		length = bufferLength;
	}

	// log the received data
#ifdef WITH_WIIUSE_DEBUG
	{
		printf("[DEBUG] (id %i) RECV: (%.2x) ", wm->unid, bytes[0]);
		int x;
		for (x = 1; x < length; ++x)
			printf("%.2x ", bytes[x]);
		printf("\n");
	}
#endif

	// copy to struct
	memcpy(buffer, bytes, length);

	return length;
}

@end

@implementation WiiuseDisconnectionMessage

- (int) applyToStruct:(wiimote *)wm buffer:(byte *)buffer length:(NSUInteger)bufferLength {
	(void)buffer;
	(void)bufferLength;
	wiiuse_disconnected(wm);
	return 0;
}

@end

#endif // __APPLE__
