import CRealtimeAtomics

// MARK: - SPSC 无锁环形缓冲区（Float PCM 样本）
//
// 专用于 CoreAudio HAL 实时回调线程（生产者）→ VAD/ASR 消费线程（消费者）
// 的样本交接。软实时（soft real-time）安全三要素：
//
// 1. **零分配**：write/read 路径只有指针运算 + memcpy + 原子 load/store，
//    无 Array/String 构造、无 ObjC 消息发送、无锁调用、无系统调用
//   （Swift 方法体内访问 let 存储属性不触发 ARC 操作）；
// 2. **无锁**：仅两个 64 位原子游标，配合位掩码取模（capacity 为 2 的
//    幂次方，`index = cursor & (capacity - 1)`），无 CAS 自旋、无等待；
// 3. **有界**：满时 write 拒绝（返回已接受数），永不阻塞音频回调线程
//   （调用方按返回值决定丢帧策略——宁可丢样本不可堵 HAL）。
//
// 内存布局：
//   storage        —— capacity 个 Float 的连续堆内存（init 一次性分配）；
//   cursorStorage  —— 2 个自然对齐的 64 位槽位：[0]=head（生产者写游标）、
//                     [1]=tail（消费者读游标）。
//
// 游标语义（**绝对样本计数，永不回绕**）：
//   - head/tail 单调递增，槽内下标 = cursor & capacityMask；
//   - 64 位计数在 48kHz 下需 1200 万年溢出，无需考虑回卷比较；
//   - 可读样本数 = head - tail（两游标差的绝对值，与下标无关）；
//   - 可写余量   = capacity - (head - tail)。
//
// 线程安全假设（SPSC 契约，违反即未定义行为）：
//   - **恰好一个生产者线程**调用 write，**恰好一个消费者线程**调用 read，
//     且二者不是同一线程（同线程调用会在满/空判定上产生数据竞争）；
//   - write 与 read 可并发执行（这正是 SPSC 无锁的意义）；
//   - head 只由生产者写、tail 只由消费者写——单写者游标无需 RMW 原子；
//   - 缓冲区对象本身须被双方线程持有强引用（ARC 引用计数是原子的）；
//     RT 路径内不得触碰任何会触发保留/释放的其他属性。
//
// 内存顺序（与 CRealtimeAtomics.h 的屏障语义一一对应）：
//   - 生产者：先写样本数据，再 `store(head, releasing)` 发布——
//     release 保证样本写入先于游标发布对消费者可见（先落盘再发布）；
//   - 消费者：`load(head, acquiring)` 读取游标——acquire 与对方的
//     release 配对构成 happens-before：消费者看到新 head 时，必然看到
//     head 之前的全部样本；
//   - 对称地，消费者写完消费进度后 `store(tail, releasing)` 发布余量，
//     生产者 `load(tail, acquiring)` 才能安全复用被释放的槽位；
//   - 读自身游标用 relaxed（自写自读，无需屏障）。
//
// 依据：单生产者单消费者 FIFO 的标准 release/acquire 发布协议
// （参见 boost::lockfree::spsc_queue 与 Kvasir "Single-Producer/Single-Consumer
// Queue"（Atomic｛C++｝）的 canonical 实现——移植协议，不引依赖）。

/// SPSC 无锁 Float 环形缓冲区。
/// - Invariant: `capacity` 为 2 的幂次方（init 强制校验）。
public final class SPSCFloatRingBuffer {

    // MARK: - 背压策略（缓冲区满时的生产者行为）
    //
    // 实时音频流的铁律：生产者（HAL 回调）**绝不等待**——禁止条件变量/
    // 信号量/自旋锁等待，满即丢弃。两种丢弃方向：
    //
    // - `.dropLatest`：丢弃**新到**样本（只收前缀）。缓冲内容保持连续，
    //   但满载期间丢的是「正在发生」的音频——适合「旧数据仍需完整处理」
    //   的下游（如完整文件级转录）。
    // - `.overwriteOldest`：写入全部新样本，**覆盖最旧**数据。缓冲永远
    //   单次写入超过容量的极端情况下只保留最新的 capacity 个样本。
    //   缓冲永远持有最近 capacity 时长的音频窗口——消费端通过游标滞后检测
    //   （lag > capacity）感知被覆盖的区间并跳过，同时打上「不连续」
    //   标记（ASR 侧据此重置流式解码状态，防止错位幻觉）。
    //   外部拾音与系统时钟严格对齐的场景（实时字幕）选这个：GPU 满载
    //   排队时，恢复后直接从最新音频继续，而不是补处理过期的旧音频。
    //
    // 覆盖模式的正确性论证（仍满足 SPSC 单写者游标不变量）：
    //   - head 仍只由生产者写（覆盖 = 照常推进 head，只是越过了 tail）；
    //   - tail 仍只由消费者写（滞后跳过在消费者线程内推进 tail）；
    //   - 消费者读区间恒为 [tail, head_snapshot)；生产者写入区间恒为
    //     [head, head+n)，二者不相交——正常负载下无数据竞争；
    //   - **过载残留风险（工程取舍）**：持续过载时生产者可能在消费者
    //     读取期间再次覆盖其窗口边缘的槽位，产生单词级 Float 撕裂。
    //     该撕裂被限制在「将被滞后跳过/不连续丢弃的区间」内，ASR 对
    //     单样本失真不敏感——音频负载本身是可丢的有损数据。
    //     需要严格无撕裂的场景请用 `.dropLatest`。

    /// 缓冲区满时生产者的丢弃策略。
    public enum OverflowPolicy: Sendable {
        /// 丢弃新到样本（只收前缀；返回值 < count 告知调用方）。
        case dropLatest
        /// 覆盖最旧样本（写入全部新样本、保留**最新**的 capacity 个样本；
        /// 消费端经游标滞后检测感知被覆盖区间）。
        case overwriteOldest
    }

    /// 环形容量（样本数；2 的幂次方）。
    public let capacity: Int
    /// 背压策略（init 注入，不可变）。
    public let overflowPolicy: OverflowPolicy
    /// 位掩码：`cursor & capacityMask` 代替 `% capacity`（2 的幂次方前提下等价且免除法）。
    private let capacityMask: Int

    /// 样本存储（连续堆内存；init 分配 / deinit 回收）。
    private let storage: UnsafeMutablePointer<Float>
    /// 游标存储：[0] = head（写游标）、[1] = tail（读游标）。
    private let cursorStorage: UnsafeMutablePointer<UInt64>

    private var headPtr: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(cursorStorage)
    }
    private var tailPtr: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(cursorStorage) + MemoryLayout<UInt64>.size
    }

    /// 容量非法（非 2 的幂次方 / 非正数）。
    public enum RingBufferError: Error, Equatable {
        case invalidCapacity(Int)
    }

    /// - Parameter capacity: 环形容量（样本数），**必须为 2 的幂次方**
    ///   （位掩码取模的前提）。建议 ≥ 2× 最大单块样本数。
    /// - Parameter overflowPolicy: 背压策略（默认经典 `.dropLatest`）。
    public init(capacity: Int, overflowPolicy: OverflowPolicy = .dropLatest) throws {
        guard capacity > 0, capacity & (capacity &- 1) == 0 else {
            throw RingBufferError.invalidCapacity(capacity)
        }
        self.capacity = capacity
        self.overflowPolicy = overflowPolicy
        self.capacityMask = capacity &- 1
        // 一次性分配：仅发生在 init（RT 路径之外）；deallocate 在 deinit。
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        cursorStorage = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
        cursorStorage[0] = 0
        cursorStorage[1] = 0
    }

    deinit {
        // 内存回收：两块堆内存各自归还（游标槽位与样本存储独立分配，
        // 因为游标需要 8 字节自然对齐且生命周期与容量解耦）。
        cursorStorage.deallocate()
        storage.deallocate()
    }

    // MARK: - 生产侧（仅 HAL 实时回调线程调用）

    /// 写入 `count` 个样本（跨环形边界自动分段拷贝）。
    ///
    /// 实时安全：无分配、无锁、无 ObjC 消息、无系统调用——**满时也绝不
    /// 等待**（背压由策略决定：丢弃新到或覆盖最旧）。
    ///
    /// - Returns: 实际接受的样本数。
    ///   `.dropLatest`：min(count, 余量)——返回值 < count 表示尾部被丢弃；
    ///   `.overwriteOldest`：恒等于 count（head 照常推进 count；
    ///   物理上只保留最新的 capacity 个样本，被覆盖的区间由消费者
    ///   经游标滞后检测跳过）。
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        // 内存顺序：head 是本线程私有游标 → relaxed 读；
        // tail 是消费者发布的进度 → acquire 读（看到 tail 推进即看到
        // 消费者已读完对应槽位，复用才安全）。
        let head = cra_load_relaxed(headPtr)
        let tail = cra_load_acquire(tailPtr)

        let n: Int
        // 真正落到存储上的样本数（≤ n）与其在 source 中的起始偏移。
        let copyCount: Int
        let sourceOffset: Int
        // 落位起点：**绝对位置 p 的样本必须存放在下标 p & capacityMask**。
        let writeStart: Int
        switch overflowPolicy {
        case .dropLatest:
            // 经典 SPSC：只收余量内的前缀，新到的尾部直接丢弃。
            let availableSpace = capacity &- Int(head &- tail)
            n = count < availableSpace ? count : availableSpace
            if n == 0 { return 0 }
            copyCount = n
            sourceOffset = 0
            // 被拒的尾部从未进入流：head 只推进 n，落位起点就是 head。
            writeStart = Int(head) & capacityMask
        case .overwriteOldest:
            // 背压覆盖：head 照常推进 count（游标语义 = 全部新样本已进入流，
            // 恒返回 count，与 doc 契约一致）。
            n = count
            // 单次写入超过容量时，块内**前段**样本会被本块自身的后段覆盖：
            // 只拷最后 capacity 个（保留最新）。若像此前那样取前缀
            // `min(count, capacity)`，丢掉的恰是**最新**样本——与「覆盖最旧、
            // 保留最新」语义相反（GPU 满载恢复后消费端会读到过期音频）。
            copyCount = Swift.min(count, capacity)
            sourceOffset = count &- copyCount
            // 被跳过的前段占用了流位置 [head, head+count-copyCount)，
            // 落位起点必须跟着前移，否则消费者按 tail = head - capacity
            // 滞后跳过后读到错位槽位（顺序被打乱成环形旋转）。
            writeStart = Int(head &+ UInt64(count &- copyCount)) & capacityMask
        }

        // 分段拷贝（ring wrap-around）：写位置可能越过存储末端，
        // 拆成 [末尾段, 回绕段] 两次连续 memcpy。
        let firstSegment = Swift.min(copyCount, capacity &- writeStart)
        storage.advanced(by: writeStart)
            .update(from: source.advanced(by: sourceOffset), count: firstSegment)
        if copyCount > firstSegment {
            storage.update(from: source.advanced(by: sourceOffset &+ firstSegment),
                           count: copyCount &- firstSegment)
        }

        // 内存屏障（release）：上面的样本写入先落盘，游标发布才对消费者可见。
        // （先落盘再发布偏移量——SPSC 发布协议的核心。）
        cra_store_release(headPtr, head &+ UInt64(n))
        return n
    }

    // MARK: - 消费侧（仅 VAD/ASR 消费线程调用）

    /// 读取至多 `count` 个样本到 `destination`（跨环形边界自动分段拷贝）。
    ///
    /// 实时安全：无分配、无锁、无 ObjC 消息、无系统调用。
    /// 缓冲区空时返回 0（调用方可决定等待策略）。
    ///
    /// `.overwriteOldest` 策略下：读取前先做**游标滞后检测**——
    /// `lag = head - tail > capacity` 说明生产者覆盖了 [lag-capacity) 区间，
    /// 消费者把 tail 直接推进到 `head - capacity`（跳过被覆盖样本），
    /// 累计丢弃数并置不连续标记（`takeDiscontinuity()` / `takeDroppedSamples()`
    /// 查询，ASR 侧据此重置流式解码状态）。tail 只由消费者写，推进合法。
    ///
    /// - Returns: 实际读取的样本数（0…count）。
    @discardableResult
    public func read(to destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        // 内存顺序：tail 是本线程私有游标 → relaxed 读；
        // head 是生产者发布的进度 → acquire 读（与生产者的 release store
        // 配对：看到新 head 时，head 之前的样本写入必然已完成可见）。
        var tail = cra_load_relaxed(tailPtr)
        let head = cra_load_acquire(headPtr)

        // 覆盖模式的滞后跳过：被覆盖区间 [tail, head-capacity) 不可读，
        // 直接放弃并在消费者私有账本上记账（单写者不变量不破坏）。
        if overflowPolicy == .overwriteOldest {
            let lag = head &- tail
            if lag > UInt64(capacity) {
                let skipped = Int(lag) &- capacity
                tail = head &- UInt64(capacity)
                // release：把跳过后的消费进度发布回生产者（余量语义不变）。
                cra_store_release(tailPtr, tail)
                droppedSamplesPending &+= skipped
                discontinuityPending = true
            }
        }

        let availableCount = Int(head &- tail)
        let n = count < availableCount ? count : availableCount
        if n == 0 { return 0 }

        // 分段拷贝（ring wrap-around）：读位置越过末端时拆两段。
        let index = Int(tail) & capacityMask
        let firstSegment = Swift.min(n, capacity &- index)
        destination.update(from: storage.advanced(by: index), count: firstSegment)
        if n > firstSegment {
            destination.advanced(by: firstSegment)
                .update(from: storage, count: n &- firstSegment)
        }

        // 内存屏障（release）：消费完成后发布 tail——生产者 acquire 到
        // 新 tail 才能安全地把释放的槽位纳入可写余量。
        cra_store_release(tailPtr, tail &+ UInt64(n))
        return n
    }

    // MARK: - 消费端丢弃记账（仅消费者线程触碰；SPSC 契约内无竞争）

    /// 自上次查询以来被覆盖丢弃的样本数（消费者线程私有账本；查询即清零）。
    public func takeDroppedSamples() -> Int {
        let value = droppedSamplesPending
        droppedSamplesPending = 0
        return value
    }

    /// 自上次查询以来是否发生过不连续（覆盖丢弃/滞后跳过；查询即清零）。
    /// ASR 消费端在 true 时应重置流式解码状态（封口当前句、清 VAD 水位线）。
    public func takeDiscontinuity() -> Bool {
        let value = discontinuityPending
        discontinuityPending = false
        return value
    }
    /// 消费者线程私有：待上报的被覆盖样本数。
    private var droppedSamplesPending = 0
    /// 消费者线程私有：待上报的不连续标记。
    private var discontinuityPending = false

    // MARK: - 状态查询（仅调试/非 RT 路径；瞬时快照，无同步保证）

    /// 当前可读样本数（瞬时快照：仅消费线程单线程读时结果可信）。
    /// 覆盖模式下滞后未消费时钳制到 capacity——超出部分已被生产者覆盖，
    /// 消费者会在下次 read 时跳过。
    public var availableToRead: Int {
        let lag = Int(cra_load_relaxed(headPtr) &- cra_load_relaxed(tailPtr))
        return lag > capacity ? capacity : lag
    }

    /// 当前可写余量（瞬时快照）。覆盖模式下滞后未消费时为 0——
    /// 原始 lag 可超过 capacity（尾部被覆盖），不允许出现负数余量。
    public var availableToWrite: Int {
        let lag = Int(cra_load_relaxed(headPtr) &- cra_load_relaxed(tailPtr))
        return lag >= capacity ? 0 : capacity &- lag
    }

    /// 复位游标。**仅在缓冲区静默（生产/消费线程均已停）时调用**——
    /// 用 relaxed 写即可，不需要屏障（无并发观察者）。
    public func resetWhenQuiesced() {
        cra_store_relaxed(headPtr, 0)
        cra_store_relaxed(tailPtr, 0)
    }
}
