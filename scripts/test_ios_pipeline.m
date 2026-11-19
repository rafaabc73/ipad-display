#import <Foundation/Foundation.h>
#import "../shared/protocol.h"
#import "../shared/lz4/lz4.h"
#include <stdio.h>
#include <assert.h>

// Mirrors the exact coalesced staging & state machine of ios/GLDisplayView.m so
// queue starvation, partial-strip flips, or missing FRAME_ACKs are caught BEFORE shipping!
@interface MockTile : NSObject
@property (nonatomic) uint16_t x, y, w, h;
@property (nonatomic) uint32_t gen;
@end
@implementation MockTile
@end

@interface MockGLState : NSObject {
    NSMutableDictionary<NSNumber *, MockTile *> *_pendingTileMap;
    NSMutableArray<NSNumber *> *_pendingAckSeqs;
    BOOL _pendingFullSyncReady;
    BOOL _hasPendingVideo;
    BOOL _needsRedraw;
}
@property (nonatomic) BOOL showVideoLayer;
@property (nonatomic) BOOL hasRetinaContent;
@property (nonatomic) BOOL hasVideoContent;
@property (nonatomic) BOOL notifiedVisible;
@property (nonatomic) NSUInteger totalUploadedTiles;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *ackedSeqs;
@end

@implementation MockGLState
- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingTileMap = [NSMutableDictionary dictionaryWithCapacity:192];
        _pendingAckSeqs = [NSMutableArray array];
        _ackedSeqs = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)queuedTileCount { return _pendingTileMap.count; }

- (void)enqueueBatchTiles:(NSArray<MockTile *> *)tiles flags:(uint8_t)flags seq:(uint32_t)seq {
    BOOL isEOF = (flags & IPD2_TILE_FLAG_END_OF_FRAME) != 0;
    BOOL isFullSync = (flags & IPD2_TILE_FLAG_FULL_SYNC) != 0;
    for (MockTile *t in tiles) {
        _pendingTileMap[@(((uint32_t)t.y << 16) | (uint32_t)t.x)] = t;
    }
    if (isFullSync && isEOF) _pendingFullSyncReady = YES;
    if (isEOF) [_pendingAckSeqs addObject:@(seq)];
    _needsRedraw = YES;
}

- (void)enqueueVideoFrame {
    _hasPendingVideo = YES;
    _pendingFullSyncReady = NO;
    _needsRedraw = YES;
}

- (BOOL)tickDisplayLink {
    if (!_needsRedraw && _pendingTileMap.count == 0 && !_hasPendingVideo && _pendingAckSeqs.count == 0) {
        return NO;
    }
    NSMutableArray<MockTile *> *tiles = nil;
    if (_pendingTileMap.count > 0) {
        if (!_showVideoLayer || _pendingTileMap.count <= 64) {
            tiles = [[_pendingTileMap allValues] mutableCopy];
            [_pendingTileMap removeAllObjects];
        } else {
            NSArray<NSNumber *> *keys = [_pendingTileMap allKeys];
            NSUInteger take = MIN(keys.count, (NSUInteger)64);
            tiles = [NSMutableArray arrayWithCapacity:take];
            for (NSUInteger i = 0; i < take; i++) {
                NSNumber *k = keys[i];
                MockTile *t = _pendingTileMap[k];
                if (t) [tiles addObject:t];
                [_pendingTileMap removeObjectForKey:k];
            }
        }
    }
    BOOL queueEmpty = (_pendingTileMap.count == 0);
    BOOL reachedFullSync = (queueEmpty && _pendingFullSyncReady);
    if (reachedFullSync) _pendingFullSyncReady = NO;

    NSArray<NSNumber *> *acks = nil;
    if (queueEmpty && _pendingAckSeqs.count > 0) {
        acks = [_pendingAckSeqs copy];
        [_pendingAckSeqs removeAllObjects];
    }

    BOOL videoPB = _hasPendingVideo;
    _hasPendingVideo = NO;
    _needsRedraw = !queueEmpty;

    if (tiles.count > 0) {
        _totalUploadedTiles += tiles.count;
        if (!_showVideoLayer || reachedFullSync) _hasRetinaContent = YES;
        if (reachedFullSync && !videoPB) {
            _hasRetinaContent = YES;
            _showVideoLayer = NO;
        }
    } else if (reachedFullSync && _hasRetinaContent && !videoPB) {
        _showVideoLayer = NO;
    }

    if (videoPB) {
        _hasVideoContent = YES;
        _showVideoLayer = YES;
    }

    BOOL useVideo = (_showVideoLayer && _hasVideoContent);
    if (!useVideo && !_hasRetinaContent) {
        if (acks) [_ackedSeqs addObjectsFromArray:acks];
        return NO;
    }
    _notifiedVisible = YES;
    if (acks) [_ackedSeqs addObjectsFromArray:acks];
    return YES;
}
@end

static NSArray<MockTile *> *makeFullFrame(uint32_t gen) {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:192];
    for (int ty = 0; ty < 12; ty++) {
        for (int tx = 0; tx < 16; tx++) {
            MockTile *t = [[MockTile alloc] init];
            t.x = (uint16_t)(tx * 128);
            t.y = (uint16_t)(ty * 128);
            t.w = 128; t.h = 128; t.gen = gen;
            [arr addObject:t];
        }
    }
    return arr;
}

int main() {
    @autoreleasepool {
        // Test 1: 3x back-to-back 192-tile full sync burst (576 tiles) must NEVER starve!
        MockGLState *st = [[MockGLState alloc] init];
        for (uint32_t f = 1; f <= 3; f++) {
            NSArray *frame = makeFullFrame(f);
            for (int b = 0; b < 24; b++) {
                NSArray *sub = [frame subarrayWithRange:NSMakeRange(b * 8, 8)];
                uint8_t fl = IPD2_TILE_FLAG_FULL_SYNC;
                [st enqueueBatchTiles:sub flags:fl seq:f * 100 + b];
            }
            // Empty EOF packet exactly like capture_engine.m line 994!
            [st enqueueBatchTiles:@[] flags:(IPD2_TILE_FLAG_FULL_SYNC | IPD2_TILE_FLAG_END_OF_FRAME) seq:f * 100 + 24];
        }
        assert(st.queuedTileCount == 192); // Coalesced 576 -> 192!
        BOOL drew = [st tickDisplayLink];
        assert(drew == YES);
        assert(st.queuedTileCount == 0);
        assert(st.hasRetinaContent == YES);
        assert(st.notifiedVisible == YES);
        assert(st.ackedSeqs.count == 3);

        // Test 2: H.264 -> Paced Retina Sharpen must NOT flip early on partial sub-batches!
        [st enqueueVideoFrame];
        assert([st tickDisplayLink] == YES);
        assert(st.showVideoLayer == YES);

        NSArray *sharpen = makeFullFrame(4);
        for (int b = 0; b < 23; b++) {
            [st enqueueBatchTiles:[sharpen subarrayWithRange:NSMakeRange(b * 8, 8)] flags:IPD2_TILE_FLAG_FULL_SYNC seq:400 + b];
        }
        [st tickDisplayLink]; // Uploads 64/184 tiles in background
        assert(st.showVideoLayer == YES); // Still clean video, zero partial-strip flash!

        [st enqueueBatchTiles:[sharpen subarrayWithRange:NSMakeRange(23 * 8, 8)]
                        flags:(IPD2_TILE_FLAG_FULL_SYNC | IPD2_TILE_FLAG_END_OF_FRAME)
                          seq:424];
        int ticks = 0;
        while (st.showVideoLayer && ticks < 10) {
            [st tickDisplayLink];
            ticks++;
        }
        assert(st.showVideoLayer == NO);   // Atomically snapped to 2048x1536 Retina!
        assert(st.queuedTileCount == 0);
        assert(st.ackedSeqs.count == 4);   // EOF ACK delivered!
        assert(ticks <= 3);                // Finished within <= 3 vsyncs (<= 50ms)!

        // Test 3: New H.264 motion supersedes pending sharpen cleanly
        [st enqueueVideoFrame];
        [st tickDisplayLink];
        assert(st.showVideoLayer == YES);
        [st enqueueBatchTiles:[sharpen subarrayWithRange:NSMakeRange(0, 64)] flags:(IPD2_TILE_FLAG_FULL_SYNC | IPD2_TILE_FLAG_END_OF_FRAME) seq:500];
        [st enqueueVideoFrame]; // New motion arrives before sharpen flips!
        [st tickDisplayLink];
        assert(st.showVideoLayer == YES);

        printf("✓ Stage 7 iOS GL Pipeline: 576->192 coalesced, 0 starvation, atomic sharpen in %d ticks, ACK=4/4\n", ticks);
    }
    return 0;
}
