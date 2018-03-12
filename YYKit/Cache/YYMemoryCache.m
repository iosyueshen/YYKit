//
//  YYMemoryCache.m
//  YYKit <https://github.com/ibireme/YYKit>
//
//  Created by ibireme on 15/2/7.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYMemoryCache.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>

#if __has_include("YYDispatchQueuePool.h")
#import "YYDispatchQueuePool.h"
#endif

#ifdef YYDispatchQueuePool_h
static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue() {
    return YYDispatchQueueGetForQOS(NSQualityOfServiceUtility);
}
#else
static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue() {
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}
#endif

/**
 A node in linked map.
 Typically, you should not use this class directly.
 */
@interface _YYLinkedMapNode : NSObject {
    @package
    __unsafe_unretained _YYLinkedMapNode *_prev; // retained by dic
    __unsafe_unretained _YYLinkedMapNode *_next; // retained by dic
    id _key;                                //缓存key
    id _value;                              //key对应值
    NSUInteger _cost;                       //缓存开销
    NSTimeInterval _time;                   //访问时间
}
@end

@implementation _YYLinkedMapNode
@end


/**
 A linked map used by YYMemoryCache.
 It's not thread-safe and does not validate the parameters.
 
 Typically, you should not use this class directly.
 */
@interface _YYLinkedMap : NSObject {
    @package
    CFMutableDictionaryRef _dic; // do not set object directly  //用于存放节点
    NSUInteger _totalCost;                                      //总开销
    NSUInteger _totalCount;                                     //节点总数
    _YYLinkedMapNode *_head; // MRU, do not change it directly  //链表的头部节点
    _YYLinkedMapNode *_tail; // LRU, do not change it directly  //链表的尾部节点
    BOOL _releaseOnMainThread;                                  //是否在主线程释放，默认为NO
    BOOL _releaseAsynchronously;                                //是否在在子线程释放，默认为YES
}

/// Insert a node at head and update the total cost.
/// Node and node.key should not be nil.
//在链表头部插入某节点
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node;

/// Bring a inner node to header.
/// Node should already inside the dic.
//将链表内部的某个节点移到链表头部
- (void)bringNodeToHead:(_YYLinkedMapNode *)node;

/// Remove a inner node and update the total cost.
/// Node should already inside the dic.
//移除某个节点
- (void)removeNode:(_YYLinkedMapNode *)node;

/// Remove tail node if exist.
//移除链表的尾部节点并返回它
- (_YYLinkedMapNode *)removeTailNode;

/// Remove all node in background queue.
//移除所有节点（默认在子线程操作）
- (void)removeAll;

@end

@implementation _YYLinkedMap

- (instancetype)init {
    self = [super init];
    _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    _releaseOnMainThread = NO;
    _releaseAsynchronously = YES;
    return self;
}

- (void)dealloc {
    CFRelease(_dic);
}

- (void)insertNodeAtHead:(_YYLinkedMapNode *)node {
    //设置该node的值
    CFDictionarySetValue(_dic, (__bridge const void *)(node->_key), (__bridge const void *)(node));
    
    //增加开销和总缓存数量
    _totalCost += node->_cost;
    _totalCount++;
    if (_head) {
        //如果链表内已经存在头节点，则将这个头节点赋给当前节点的尾指针（原第一个节点变成现第二个节点）
        node->_next = _head;
        //将该节点赋给现第二个节点的头指针（此时_head指向的节点是先第二个节点）
        _head->_prev = node;
        //将该节点赋给链表的头节点指针（该节点变成了现第一个节点）
        _head = node;
    } else {
        //如果链表内没有头节点，说明是空链表，则将链表的头尾节点都设置为当前节点
        _head = _tail = node;
    }
}

- (void)bringNodeToHead:(_YYLinkedMapNode *)node {
    //如果该节点已经是链表头部节点，则立即返回，不做任何操作
    if (_head == node) return;
    
    if (_tail == node) {
        //如果该节点是链表的尾部节点
        //1. 将该节点的头指针指向的节点变成链表的尾节点（将倒数第二个节点变成倒数第一个节点，即尾部节点）
        _tail = node->_prev;
        //2. 将新的尾部节点的尾部指针置空
        _tail->_next = nil;
    } else {
        //如果该节点是链表头部和尾部以外的节点（中间节点）
        //1. 将该node的头指针指向的节点赋给其尾指针指向的节点的头指针
        node->_next->_prev = node->_prev;
        //2. 将该node的尾指针指向的节点赋给其他指针指向的节点的尾指针
        node->_prev->_next = node->_next;
    }
    //将原头节点赋给该节点的尾指针（原第一个节点变成了现第二个节点）
    node->_next = _head;
    //将当前节点的头节点置空
    node->_prev = nil;
    //将现第二个节点的头节点指向当前节点（此时_head指向的节点是第一个节点）
    _head->_prev = node;
    //将该节点设置为链表的头节点
    _head = node;
}

- (void)removeNode:(_YYLinkedMapNode *)node {
    //除去该node的键对应的值
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key));
    
    //减去开销和总缓存数量
    _totalCost -= node->_cost;
    _totalCount--;
    
    //节点操作
    //1. 将该node的头指针指向的节点赋给其尾指针指向的节点的头指针
    if (node->_next) node->_next->_prev = node->_prev;
    
    //2. 将该node的尾指针指向的节点赋给其头指针指向的节点的尾指针
    if (node->_prev) node->_prev->_next = node->_next;
    
    //3. 如果该node就是链表的头节点，则将该node的尾部指针指向的节点赋给链表的头节点（第二变成了第一）
    if (_head == node) _head = node->_next;
    
    //4. 如果该node就是链表的尾节点，则将该node的头部指针指向的节点赋给链表的尾节点（倒数第二变成了倒数第一）
    if (_tail == node) _tail = node->_prev;
}

- (_YYLinkedMapNode *)removeTailNode {
    
    //如果不存在尾节点，则返回nil
    if (!_tail) return nil;
    _YYLinkedMapNode *tail = _tail;
    
    //移除尾部节点对应的值
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key));
    
    //减少开销和总缓存数量
    _totalCost -= _tail->_cost;
    _totalCount--;
    
    if (_head == _tail) {
        //如果链表的头尾节点相同，说明链表只有一个节点。将其置空
        _head = _tail = nil;
    } else {
        //将链表的尾节指针指向的指针赋给链表的尾指针（倒数第二变成了倒数第一）
        _tail = _tail->_prev;
        //将新的尾节点的尾指针置空
        _tail->_next = nil;
    }
    return tail;
}

- (void)removeAll {
    _totalCost = 0;
    _totalCount = 0;
    _head = nil;
    _tail = nil;
    if (CFDictionaryGetCount(_dic) > 0) {
        CFMutableDictionaryRef holder = _dic;
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        
        if (_releaseAsynchronously) {
            dispatch_queue_t queue = _releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                CFRelease(holder); // hold and release in specified queue
            });
        } else if (_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CFRelease(holder); // hold and release in specified queue
            });
        } else {
            CFRelease(holder);
        }
    }
}

@end



@implementation YYMemoryCache {
    pthread_mutex_t _lock;
    _YYLinkedMap *_lru;
    dispatch_queue_t _queue;
}

//递归清理，相隔时间间隔为_autoTrimInterval，在初始化之后立即执行
- (void)_trimRecursively {
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        __strong typeof(_self) self = _self;
        if (!self) return;
        
        //在后台进行清理操作
        [self _trimInBackground];
        
        //调用自己，递归操作
        [self _trimRecursively];
    });
}

//清理所有不符合限制的缓存，顺序为：cost，count，age
- (void)_trimInBackground {
    dispatch_async(_queue, ^{
        [self _trimToCost:self->_costLimit];
        [self _trimToCount:self->_countLimit];
        [self _trimToAge:self->_ageLimit];
    });
}

- (void)_trimToCost:(NSUInteger)costLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    if (costLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCost <= costLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCost > costLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

//将内存缓存数量降至等于或小于传入的数量；如果传入的值为0，则删除全部内存缓存
- (void)_trimToCount:(NSUInteger)countLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    
    //如果传入的参数=0，则删除所有内存缓存
    if (countLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCount <= countLimit) {
        
        //如果当前缓存的总数量已经小于或等于传入的数量，则直接返回YES，不进行清理
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        
        //==0的时候说明在尝试加锁的时候，获取锁成功，从而可以进行操作；否则等待10秒（但是不知道为什么是10s而不是2s，5s，等等）
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCount > countLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_trimToAge:(NSTimeInterval)ageLimit {
    BOOL finish = NO;
    NSTimeInterval now = CACurrentMediaTime();
    pthread_mutex_lock(&_lock);
    if (ageLimit <= 0) {
        [_lru removeAll];
        finish = YES;
    } else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_appDidReceiveMemoryWarningNotification {
    if (self.didReceiveMemoryWarningBlock) {
        self.didReceiveMemoryWarningBlock(self);
    }
    if (self.shouldRemoveAllObjectsOnMemoryWarning) {
        [self removeAllObjects];
    }
}

- (void)_appDidEnterBackgroundNotification {
    if (self.didEnterBackgroundBlock) {
        self.didEnterBackgroundBlock(self);
    }
    if (self.shouldRemoveAllObjectsWhenEnteringBackground) {
        [self removeAllObjects];
    }
}

#pragma mark - public

- (instancetype)init {
    self = super.init;
    pthread_mutex_init(&_lock, NULL);
    _lru = [_YYLinkedMap new];
    _queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);
    
    _countLimit = NSUIntegerMax;
    _costLimit = NSUIntegerMax;
    _ageLimit = DBL_MAX;
    _autoTrimInterval = 5.0;
    _shouldRemoveAllObjectsOnMemoryWarning = YES;
    _shouldRemoveAllObjectsWhenEnteringBackground = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidReceiveMemoryWarningNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidEnterBackgroundNotification) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    //开始定期清理
    [self _trimRecursively];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [_lru removeAll];
    pthread_mutex_destroy(&_lock);
}

- (NSUInteger)totalCount {
    pthread_mutex_lock(&_lock);
    NSUInteger count = _lru->_totalCount;
    pthread_mutex_unlock(&_lock);
    return count;
}

- (NSUInteger)totalCost {
    pthread_mutex_lock(&_lock);
    NSUInteger totalCost = _lru->_totalCost;
    pthread_mutex_unlock(&_lock);
    return totalCost;
}

- (BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    BOOL releaseOnMainThread = _lru->_releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
    return releaseOnMainThread;
}

- (void)setReleaseOnMainThread:(BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    _lru->_releaseOnMainThread = releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    BOOL releaseAsynchronously = _lru->_releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
    return releaseAsynchronously;
}

- (void)setReleaseAsynchronously:(BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    _lru->_releaseAsynchronously = releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
}

//是否包含某个缓存对象
- (BOOL)containsObjectForKey:(id)key {
    
    //尝试从内置的字典中获取缓存对象
    if (!key) return NO;
    pthread_mutex_lock(&_lock);
    BOOL contains = CFDictionaryContainsKey(_lru->_dic, (__bridge const void *)(key));
    pthread_mutex_unlock(&_lock);
    return contains;
}

//获取某个缓存对象
- (id)objectForKey:(id)key {
    if (!key) return nil;
    pthread_mutex_lock(&_lock);
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        //如果节点存在，则更新它的时间信息（最后一次访问的时间）
        node->_time = CACurrentMediaTime();
        [_lru bringNodeToHead:node];
    }
    pthread_mutex_unlock(&_lock);
    return node ? node->_value : nil;
}

//写入某个缓存对象，开销默认为0
- (void)setObject:(id)object forKey:(id)key {
    [self setObject:object forKey:key withCost:0];
}

//写入某个缓存对象，并存入缓存开销
- (void)setObject:(id)object forKey:(id)key withCost:(NSUInteger)cost {
    if (!key) return;
    if (!object) {
        [self removeObjectForKey:key];
        return;
    }
    pthread_mutex_lock(&_lock);
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    NSTimeInterval now = CACurrentMediaTime();
    if (node) {
        //如果存在与传入的key值匹配的node，则更新该node的value，cost，time，并将这个node移到链表头部
        
        //更新总cost
        _lru->_totalCost -= node->_cost;
        _lru->_totalCost += cost;
        
        //更新node
        node->_cost = cost;
        node->_time = now;
        node->_value = object;
        
        //将node移动至链表头部
        [_lru bringNodeToHead:node];
    } else {
        //如果不存在与传入的key值匹配的node，则新建一个node，将key，value，cost，time赋给它，并将这个node插入到链表头部
        //新建node，并赋值
        node = [_YYLinkedMapNode new];
        node->_cost = cost;
        node->_time = now;
        node->_key = key;
        node->_value = object;
        
        //将node插入至链表头部
        [_lru insertNodeAtHead:node];
    }
    
    //如果cost超过了限制，则进行删除缓存操作（从链表尾部开始删除，直到符合限制要求）
    if (_lru->_totalCost > _costLimit) {
        dispatch_async(_queue, ^{
            [self trimToCost:_costLimit];
        });
    }
    
    //如果total count超过了限制，则进行删除缓存操作（从链表尾部开始删除，删除一次即可）
    if (_lru->_totalCount > _countLimit) {
        _YYLinkedMapNode *node = [_lru removeTailNode];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

//移除某个缓存对象
- (void)removeObjectForKey:(id)key {
    if (!key) return;
    pthread_mutex_lock(&_lock);
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        
        //内部调用了链表的removeNode：方法
        [_lru removeNode:node];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

//内部调用了链表的removeAll方法
- (void)removeAllObjects {
    pthread_mutex_lock(&_lock);
    [_lru removeAll];
    pthread_mutex_unlock(&_lock);
}

- (void)trimToCount:(NSUInteger)count {
    if (count == 0) {
        [self removeAllObjects];
        return;
    }
    [self _trimToCount:count];
}

- (void)trimToCost:(NSUInteger)cost {
    [self _trimToCost:cost];
}

- (void)trimToAge:(NSTimeInterval)age {
    [self _trimToAge:age];
}

- (NSString *)description {
    if (_name) return [NSString stringWithFormat:@"<%@: %p> (%@)", self.class, self, _name];
    else return [NSString stringWithFormat:@"<%@: %p>", self.class, self];
}

@end
