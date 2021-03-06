/* SKID - System Key Intercept and Dispatch
 * Copyright (C) 2013 Brad Allred
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

#import "SKID_Assistant.h"

#define CG_EXTERN_C_BEGIN
#define CG_EXTERN_C_END

#import "CGS/CGSConnection.h"
#import "CGS/CGSMisc.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSRunningApplication.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSWorkspace.h>

#pragma mark EventTapCallback
CGEventRef sessionEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);
CGEventRef sessionEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
	int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
	if (userData) {
		NSLog(@"intercepted event being dispatched to:%lld", userData);
		ProcessSerialNumber psn = *(ProcessSerialNumber*)&userData;
		CGEventPostToPSN(&psn, event);
		CGEventPost(kCGAnnotatedSessionEventTap, event);
		return NULL;
	}
	return event;
}

CGEventRef myCGEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);
CGEventRef myCGEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
	/*
	if (type == kCGEventRightMouseDown) {
		NSLog(@"CGEvent data dump:");
		for (int i=0; i <= 99; i++) {
			printf("field %i=%lld\n", i, CGEventGetIntegerValueField(event, i));
		}

		NSArray* windows = (NSArray*)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
		NSInteger winID = 0;
		for (NSDictionary* attributes in windows) {
			//context menus are windows too. lets skip those
			int winLvl = [[attributes valueForKey:(NSString*)kCGWindowLayer] intValue];
			if ([[attributes valueForKey:(NSString*)kCGWindowOwnerPID] intValue] == 2846 
				&& (winLvl == kCGNormalWindowLevel || winLvl == 25)) {
				winID = [[attributes valueForKey:(NSString*)kCGWindowNumber] integerValue];
				NSLog(@"Target window dump:\n%@", attributes);
				break;
			}
		}
		ProcessSerialNumber psn = { 0, kCurrentProcess};
		GetFrontProcess(&psn);
		
		CGEventPostToPSN(&psn, event);
		return NULL;
	}
	*/
	SKID_Assistant* assistant = [SKID_Assistant sharedAssistant];
	//Do not make the NSEvent here. 
	//NSEvent will throw an exception if we try to make an event from the tap timout type
	if (type != kCGEventTapDisabledByUserInput && [assistant processEvent:event]) {
		return NULL;//remove from queue
	}
	//we werent interested in the event or there was an error.
	return event;
}

#pragma mark SKID Assistant implemetation
@implementation SKID_Assistant
#pragma mark singleton inmplemetation
// use singleton design pattern
static SKID_Assistant *sharedAssistant = nil;

+ (SKID_Assistant*)sharedAssistant
{
    @synchronized(self) {
        if (sharedAssistant == nil) {
            [[self alloc] init];
        }
    }
    return sharedAssistant;
}

+ (id)allocWithZone:(NSZone *)zone
{
    @synchronized(self) {
        if (sharedAssistant == nil) {
            return [super allocWithZone:zone];
        }
    }
    return sharedAssistant;
}

- (id)init
{
    Class myClass = [self class];
    @synchronized(myClass) {
        if (sharedAssistant == nil) {
            if (self = [super init]) {
				_vendorConnection = [NSConnection new];
				[_vendorConnection setRootObject:self];

				if (![_vendorConnection registerName:SKID_AGENT_NAME]){
					NSLog(@"Unable to register SkidAgent service. Exiting.");
					[super release]; //singleton. must call on super.
					// completely fail and die.
					exit(EXIT_FAILURE);
				}
				sharedAssistant = self;

				_arPool = [[NSAutoreleasePool alloc] init];

				_functionKeyLookup = [[NSDictionary alloc] initWithObjectsAndKeys:
									  @SKID_KEY_F1, SKID_EV_DATA_F1,
									  @SKID_KEY_F2, SKID_EV_DATA_F2,
									  @SKID_KEY_F3, S(SKID_KEY_EXPOSE),
									  @SKID_KEY_F4, S(SKID_KEY_DASHBOARD),
									  @SKID_KEY_F5, SKID_EV_DATA_F5,
									  @SKID_KEY_F6, SKID_EV_DATA_F6,
									  @SKID_KEY_F7, SKID_EV_DATA_F7,
									  @SKID_KEY_F8, SKID_EV_DATA_F8,
									  @SKID_KEY_F9, SKID_EV_DATA_F9,
									  @SKID_KEY_F10, SKID_EV_DATA_F10,
									  @SKID_KEY_F11, SKID_EV_DATA_F11,
									  @SKID_KEY_F12, SKID_EV_DATA_F12, nil];

				//we need to capture all key up/down and all mouse up/down
				_runLoopSource = NULL;
				_eventTap = NULL;
				_eventMask = 0;

				NSDistributedNotificationCenter* dnc = [NSDistributedNotificationCenter notificationCenterForType:NSLocalNotificationCenterType];
				[dnc addObserver:self selector:@selector(prefrencesChanged:) name:@"SKID_SystemKeysChanged" object:nil];
				[dnc addObserver:self selector:@selector(prefrencesChanged:) name:@"SKID_FiltersChanged" object:nil];

				_prefCoordinator = [SKID_PreferenceCoordinator sharedCoordinator];
            }
        }
    }
    return sharedAssistant;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (id)retain { return self; }

- (unsigned)retainCount { return UINT_MAX; }

- (oneway void)release {}

- (id)autorelease { return self; }

#pragma mark SKID Assistant protocol methods
- (oneway void)terminate
{
	//calling stop will lead to agent termination
	NSLog(@"stopping agent service");
	[_vendorConnection invalidate];
	[_vendorConnection release];
	
	NSDistributedNotificationCenter* dnc = [NSDistributedNotificationCenter notificationCenterForType:NSLocalNotificationCenterType];
	[dnc removeObserver:self];// unsubscrible ALL notifications.
	
	//need to remove our run loop source
	//once removed listen should return
	
	if (_runLoopSource){
		CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _runLoopSource, kCFRunLoopCommonModes);
		CFRelease(_runLoopSource);
	}
	if (_eventTap){
		//kill the event tap
		CGEventTapEnable(_eventTap, FALSE);
		CFRelease(_eventTap);
	}

	//CFRunLoopStop(CFRunLoopGetCurrent());
}

#pragma mark Skid Assistant methods

- (BOOL)tapActive
{
	return CGEventTapIsEnabled(_eventTap);
}

- (BOOL)tapEvents
{
	//reload the system settings so that we know what events we will continue to handle
	[_prefCoordinator reloadPreferences];
	if (!_eventTap) {
		NSLog(@"Initializing an event tap.");
		//create the event tap
		CGEventMask eventMask = kCGEventMaskForAllEvents;
		//clear mouse move events. we NEVER want those.
		eventMask &= ~(CGEventMaskBit(kCGEventMouseMoved));
		//clear scroll whell events
		eventMask &= ~(CGEventMaskBit(kCGEventScrollWheel));
		//clear mouse drag events too
		eventMask &= ~(CGEventMaskBit(kCGEventLeftMouseDragged));
		eventMask &= ~(CGEventMaskBit(kCGEventRightMouseDragged));
		eventMask &= ~(CGEventMaskBit(kCGEventOtherMouseDragged));
		//clear misc
		// I dont know how this could happen, but block it because if it did happen 
		// and we tried to handle the event, it would cause an exception
		//eventMask &= ~(CGEventMaskBit(kCGEventTapDisabledByUserInput));
		
		_eventTap = CGEventTapCreate(
						 kCGSessionEventTap, kCGHeadInsertEventTap,
						 kCGEventTapOptionDefault, eventMask, myCGEventCallback, NULL);
	}
	CGEventTapEnable(_eventTap, TRUE);

	return [self tapActive];
}

// this is a blocking call.
// it will add our event tap as a run loop source and
// run the runloop until the source is removed
// as that point listen will return
- (void)listen
{
	/*
	CGEventTapInformation tapList[10];
	CGTableCount tapCount = 0;
	CGGetEventTapList(10, tapList, &tapCount);
	
	for (int i = 0; i < tapCount; i++) {
		if (tapList[i].enabled && tapList[i].options == 0) {
			NSLog(@"found a tap from %u monitoring %u", tapList[i].tappingProcess, tapList[i].processBeingTapped);
		}
	}
	*/
	if (!_runLoopSource) {
		if (_eventTap) {//dont use [self tapActive]
			_runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
														   _eventTap, 0);
			// Add to the current run loop.
			CFRunLoopAddSource(CFRunLoopGetCurrent(), _runLoopSource,
							   kCFRunLoopCommonModes);
			
			NSLog(@"Registering event tap as run loop source.");
		}else{
			NSLog(@"No Event tap in place! You will need to call listen after tapEvents to get events.");
		}
		CFRunLoopRun();
	}
}

- (BOOL)willInterceptMouseButton:(NSInteger)button
{
	MouseButtonFlags mcButtons = [_prefCoordinator AllMissionControlMouseButtons];
	if (((1 << button) & mcButtons )) {
		NSLog(@"Will intercept mouse button %i", button+1);
		return YES;
	}
	return NO;
}

- (BOOL)willInterceptKeyboardKey:(UInt16)keyCode
{
	//check if the key is a function key
	return ( SKID_KEY_EXPOSE == keyCode || 
			  SKID_KEY_DASHBOARD == keyCode || 
			  SKID_KEY_BRIGHTNESS_DOWN == keyCode || 
			  SKID_KEY_BRIGHTNESS_UP == keyCode
			);
}

- (BOOL)willInterceptEvent:(NSEvent*)event WithFilters:(SKID_ApplicationFilters*)filters
{
	NSEventType type = [event type];
	//check if we are even interested in the event type
	if ( (CGEventMaskBit(type) & _eventMask) ){
		//reduce the type to either mouse or keyboard button
		switch (type) {
			// mouse
			case NSLeftMouseDown:
			case NSLeftMouseUp:
			case NSRightMouseDown:
			case NSRightMouseUp:
			case NSOtherMouseDown:
			case NSOtherMouseUp:{
				NSInteger mouseBtn = [event buttonNumber];
				if (![self willInterceptMouseButton:mouseBtn])				return NO;
				if (![filters filteringMouseEventsForButton:mouseBtn])		return NO;
			}
				break;
			// keyboard
			case NSKeyDown:
			case NSKeyUp:{
				UInt16 keyCode = [event keyCode];
				if (![self willInterceptKeyboardKey:keyCode])				return NO;
				if (![filters filteringKeyboardEventsForKeyCode:keyCode])	return NO;
			}
				break;
			//special keyboard function keys
			case NSSystemDefined:
				if ([event subtype] == 8) {
					NSLog(@"special event");
					UInt16 keyCode = (([event data1] & 0xFFFF0000) >> 16);
					if (![filters filteringKeyboardEventsForKeyCode:keyCode]) return NO;
					break;
				}
			default:														return NO; //should never happen.
		}

		NSLog(@"Will intercept event");
		return YES;//passed the gauntlet
	}
	return NO;
}

- (SKID_ApplicationFilters*)filtersForActiveApplication:(NSRunningApplication**)activeApp
{
	NSWorkspace* ws = [NSWorkspace sharedWorkspace];
	for( NSRunningApplication* app in [ws runningApplications] ){
		if (app.isActive){
			*activeApp = [[app retain] autorelease];
			return [_prefCoordinator filtersForRunningApp:app];
		}
	}
	return nil;
}

- (void)prefrencesChanged:(NSNotification*)notice
{
	if (![[notice object] isEqualToString:[NSString stringWithFormat:@"0x%08X", _prefCoordinator]]) {
		NSLog(@"notification from %@ is not our coordinator:%@", [notice object], [NSString stringWithFormat:@"0x%08X", _prefCoordinator]);
		[_prefCoordinator reloadPreferences];
		// our coordinator reloading will re-post the notification
		return;
	}
	NSLog(@"Received notification that prefrences have changed.");
	_eventMask = 0;
	if(![_prefCoordinator standardFnKeys]){// we only care about key events if the fn keys are being "special"
		_eventMask |= (CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp));
		// most special function keys send special system events instead of key events
		// we need to tap those events too
		_eventMask |= CGEventMaskBit(NSSystemDefined);
	}
	MouseButtonFlags mcButtons = [_prefCoordinator AllMissionControlMouseButtons];
	if (mcButtons | SKID_LEFT_MOUSE)
	{
		_eventMask |= (CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp));
	}
	if (mcButtons | SKID_RIGHT_MOSUE)
	{
		_eventMask |= (CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp));
	}
	if (mcButtons | SKID_OTHER_MOUSE)
	{
		_eventMask |= (CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp));
	}
	NSLog(@"Event Mask set to:%llx", _eventMask);
}

// Note: the screen visible rect that is supposed to take dock/menubar into consideration
// doesnt seem to consider the dock height when it is set to hidden and then exposed by the mouse
// we have to do this another, more horrible way.
- (BOOL)pointIntercectsWithDock:(NSPoint) point
{
	NSRect dockWinFrame = NSZeroRect;

	pid_t dockPid = [[[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"] objectAtIndex:0] processIdentifier];
	// FIXME: this is relatively expensive. maybe there is a way to do this conditionally
	NSArray* windows = (NSArray*)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
	for (NSDictionary* winDict in windows) {
		// TODO: find out if there is a better way to find this.
		int winPid = [[winDict valueForKey:(NSString*)kCGWindowOwnerPID] intValue];
		// when the dock is hidden there is no way to find out if the mouse is hovering over it when it appears
		// however, when it is revealed a window called "Magic Mirror" is created and shown
		// obviously this is not backwards compatible with versions of Mac OS before the magic mirror
		// also this does not work well at all with magnification.
		NSString* winName = [winDict valueForKey:(NSString*)kCGWindowName];
		if (winPid == dockPid && [winName isEqualToString:@"Magic Mirror"]) {
			CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)[winDict valueForKey:(NSString*)kCGWindowBounds], (CGRect*)&dockWinFrame);
			// the mirror is always about 75% of actual dock height.
			if (dockWinFrame.size.height > dockWinFrame.size.width) {
				// on the side of screen
				dockWinFrame.size.width *= 1.5; // FIXME: this is a guess.
				// TODO: implement origin for dock on side
			} else {
				// bottom of screen
				dockWinFrame.size.height *= 1.5; // FIXME: this is a guess.
				dockWinFrame.origin.y = 0;//[NSScreen mainScreen].frame.size.height - dockWinFrame.size.height;
			}
			break; // assume only 1 dock window
		}
	}
	
	NSLog(@"testing if point %@ lies within %@",
		  NSStringFromPoint(point),
		  NSStringFromRect(dockWinFrame));
	return NSMouseInRect(point, dockWinFrame, NO);
}

- (BOOL)processEvent:(CGEventRef)cgEvent
{		
	NSEventType type = (NSEventType)CGEventGetType(cgEvent);

	if(type == kCGEventTapDisabledByTimeout) {
		NSLog(@"event tap has timed out, re-enabling tap");
		return [self tapEvents];
	}

	//drain and reset the pool for the each non-timeout event.
	[_arPool release];
	_arPool = [[NSAutoreleasePool alloc] init];

	NSEvent* event = nil;
	@try {			
		// MUST create NSEvent AFTER handling tap timeouts or an exception occurs
		event = [NSEvent eventWithCGEvent:cgEvent];

		NSRunningApplication* activeApp = nil;
		SKID_ApplicationFilters* filters = [self filtersForActiveApplication:&activeApp];
		NSNumber* fnKeyCode = nil;
		BOOL keyState = NO;

		if (filters && [self willInterceptEvent:event WithFilters:filters]) {
			pid_t pid = [activeApp processIdentifier];
			ProcessSerialNumber psn = { 0, kCurrentProcess};
			GetProcessForPID(pid, &psn);
			NSAssert(psn.lowLongOfPSN != kNoProcess, @"Could not get PSN for front process.");
			// if the event is a special system event from functionn keys we need to 
			// create a new event, but NOT RELEASE the old one; it is owned by the system.
			if ( type == NSSystemDefined && [event subtype] == 8) {
				UInt16 keyCode = (([event data1] & 0xFFFF0000) >> 16);
				NSInteger keyFlags = ([event data1] & 0x0000FFFF);
				keyState = (((keyFlags & 0xFF00) >> 8)) == 0xA; // true => keyDown
				NSString* lookupKey = [NSString stringWithFormat:@"0x%04X", keyCode];
				fnKeyCode = [_functionKeyLookup objectForKey:lookupKey];
			}else if( type == NSKeyDown || type == NSKeyUp){
				keyState = (type == NSKeyDown);
				NSString* lookupKey = [NSString stringWithFormat:@"0x%04X", [event keyCode]];
				fnKeyCode = [_functionKeyLookup objectForKey:lookupKey];
			}
			CGEventRef newCGEvent = NULL;//cgEvent;
			//CGEventRef moveCGEvent = NULL;
			if (fnKeyCode) { 
				CGEventSourceRef sourceRef = CGEventCreateSourceFromEvent(cgEvent);
				newCGEvent = CGEventCreateKeyboardEvent(sourceRef, [fnKeyCode intValue], keyState);
				CFRelease(sourceRef);
			} else {
				//set ourselves up as a "universal owner" to the window server
				pid_t dockPid = [[[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"] objectAtIndex:0] processIdentifier];
				ProcessSerialNumber dockPsn = {0, 0};
				GetProcessForPID(dockPid, &dockPsn);
				CGSConnectionID myCid = CGSMainConnectionID();
				CGSConnectionID universalCon = 0;
				CGSGetConnectionIDForPSN(myCid, &dockPsn, &universalCon);
				CGSSetOtherUniversalConnection(universalCon, myCid);

				// for now we dont need to assign send key events to a window
				// !!!: !fnKeyCode assumes that makes this a mouse event! this is true, but maybe in the future it wont be.
				CGPoint mousePoint = CGEventGetUnflippedLocation(cgEvent);
				CGPoint clickPoint;
				//NSArray* windows = (NSArray*)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
				NSInteger winID = 0;
				int cidOut;
				CGSFindWindowByGeometry(myCid, 0, 1, 0, &mousePoint, &clickPoint, &winID, &cidOut);

				int frontCid;
				CGSGetConnectionIDForPSN(myCid, &psn, &frontCid);
				if (cidOut != frontCid || [self pointIntercectsWithDock:NSPointFromCGPoint(mousePoint)]) {
					// only interested in active processes windows
					return NO;
				}

				NSArray* windows = (NSArray*)CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly
																		| kCGWindowListExcludeDesktopElements
																		| kCGWindowListOptionOnScreenAboveWindow,
																		winID);
				for (NSDictionary* winDict in windows) {
					// TODO: find out if there is a better way to find this.
					int winPid = [[winDict valueForKey:(NSString*)kCGWindowOwnerPID] intValue];
					int winLayer = [[winDict valueForKey:(NSString*)kCGWindowLayer] intValue];
					if (
						// popup windows (context menus) always have priority, regardless of owner pid
						// we COULD intercect the window rects with the event location,
						// i feel this to be unnecessary since it is a context menu and the user probably doesnt want us eating events for it
							winLayer == kCGPopUpMenuWindowLevel

						// only worry about front processes windows
						||( winPid == pid
						    // ignore invisible windows or special UI windows (popup windows handled previously)
						&&  [[winDict valueForKey:(NSString*)kCGWindowAlpha] floatValue] > 0.0
						&&  winLayer == kCGNormalWindowLevel
						  )
					   )
					{
						// another window has focus / priority
						return NO;
					}
				}
				// CGWindowListCopyWindowInfo say we should release.
				[windows release];
				if (winID) {
					NSEvent* newEvent = [NSEvent mouseEventWithType:[event type]
														   location: NSPointFromCGPoint(mousePoint)
													  modifierFlags:[event modifierFlags]
														  timestamp:[event timestamp] 
													   windowNumber:winID
															context:nil 
														eventNumber:[event eventNumber] + 1
														 clickCount:[event clickCount]
														   pressure:0];
/*
					NSEvent* moveEvent = [NSEvent mouseEventWithType:NSMouseMoved
															location:*(NSPoint*)&clickPoint
													   modifierFlags:0
														   timestamp:[event timestamp] 
														windowNumber:winID
															 context:nil 
														 eventNumber:[event eventNumber]
														  clickCount:0
															pressure:0];

					moveCGEvent = [moveEvent CGEvent];
 */
					newCGEvent = [newEvent CGEvent];
					CFRetain(newCGEvent);
				} else {
					return NO;
				}
			}

			NSLog(@"forwarding event: %@", event);
			CGEventPostToPSN(&psn, newCGEvent);
			NSLog(@"intercepted event being dispatched to:%@ - %lu", [activeApp localizedName], psn.lowLongOfPSN);

			CFRelease(newCGEvent);
			return YES;
		}
		
	}
	@catch (NSException *exception) {
		// this is just in case i missed something non-obvious
		if ([[exception name] isEqualToString:NSInternalInconsistencyException]) {
			NSLog(@"Event caused an InternalInconsistencyException:\n%@", [event description]);
		}else{
			@throw exception;
		}
	}
	return NO;
}

- (void)dealloc
{
	//this will probably never get called.
	if (_vendorConnection) [self terminate];
	
	[_functionKeyLookup release];
	
	[_arPool release];
	[super dealloc];
}

@end
