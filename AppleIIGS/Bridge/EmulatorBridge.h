#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GSDiskSlot) {
    GSDiskSlotS5D1 NS_SWIFT_NAME(s5D1) = 0,
    GSDiskSlotS5D2 NS_SWIFT_NAME(s5D2) = 1,
    GSDiskSlotS6D1 NS_SWIFT_NAME(s6D1) = 2,
    GSDiskSlotS6D2 NS_SWIFT_NAME(s6D2) = 3,
    GSDiskSlotS7D1 NS_SWIFT_NAME(s7D1) = 4,
    GSDiskSlotS7D2 NS_SWIFT_NAME(s7D2) = 5,
};

typedef NS_ENUM(NSInteger, GSSpeed) {
    GSSpeedSlow      NS_SWIFT_NAME(slow)      = 1,
    GSSpeedNormal    NS_SWIFT_NAME(normal)    = 2,
    GSSpeedFast      NS_SWIFT_NAME(fast)      = 3,
    GSSpeedUnlimited NS_SWIFT_NAME(unlimited) = 0,
};

@protocol EmulatorBridgeDelegate <NSObject>
- (void)emulatorDidUpdateFrame;
- (void)emulatorDidChangeDiskLight:(BOOL)on slot:(NSInteger)slot drive:(NSInteger)drive track:(NSInteger)track;
@end

@interface EmulatorBridge : NSObject

@property (nonatomic, weak, nullable) id<EmulatorBridgeDelegate> delegate;

// Framebuffer info (BGRA, premultiplied)
@property (nonatomic, readonly) NSInteger frameWidth;
@property (nonatomic, readonly) NSInteger frameHeight;
@property (nonatomic, readonly) NSInteger frameBytesPerRow;
@property (nonatomic, readonly, nullable) const uint8_t *frameBufferPtr NS_RETURNS_INNER_POINTER;

// Lifecycle
+ (instancetype)shared;

- (void)start;
- (void)pause;
- (void)resume;
- (void)reset;          // Soft reset (Ctrl-Reset)
- (void)coldBoot;       // Cold boot (Ctrl-Cmd-Reset)
- (void)shutdown;

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL isInitialized;
@property (nonatomic, readonly) float currentMHz;

// Configuration
- (void)setSpeed:(GSSpeed)speed;
- (GSSpeed)speed;
- (void)setColorMonitor:(BOOL)color;

// Keyboard
- (void)keyDown:(int)a2code;
- (void)keyUp:(int)a2code;
- (void)typeText:(NSString *)text;     // Convenience for software keyboard

// Joystick / paddle (each in -1..+1)
- (void)setJoystickX:(float)x y:(float)y;
- (void)setJoystickButton:(int)button pressed:(BOOL)pressed; // 0 = open-apple, 1 = closed-apple

// Disk management
- (BOOL)insertDiskAtPath:(NSString *)path slot:(GSDiskSlot)slot;
- (void)ejectDisk:(GSDiskSlot)slot;
- (nullable NSString *)mountedDiskPath:(GSDiskSlot)slot;

// Save state
- (BOOL)saveStateToPath:(NSString *)path;
- (BOOL)loadStateFromPath:(NSString *)path;

// Frame capture for thumbnails
- (nullable UIImage *)snapshotImage;

@end

NS_ASSUME_NONNULL_END
