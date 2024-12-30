---
title: "Java & Go 并发编程对比"
date: 2019-07-15T16:55:32+08:00
lastmod: 2024-12-30T08:45:32+08:00
draft: false
keywords: ["Go","Java","Concurrency"]
description: "Java & Go 并发编程对比"
tags: ["Go","Java","Concurrency"]
author: "Zeng Xu"
summary: "Java & Go 并发编程对比"

comment: false
toc: true
autoCollapseToc: false
postMetaInFooter: true
hiddenFromHomePage: false
contentCopyright:  '本作品采用 <a rel="license noopener" href="https://creativecommons.org/licenses/by-nc-nd/4.0/" target="_blank">知识共享署名-非商业性使用-禁止演绎 4.0 国际许可协议</a> 进行许可，转载时请注明原文链接。'    
reward: false
mathjax: false
mathjaxEnableSingleDollar: false
mathjaxEnableAutoNumber: false

# You unlisted posts you might want not want the header or footer to show
hideHeaderAndFooter: false

# You can enable or disable out-of-date content warning for individual post.
# Comment this out to use the global config.
#enableOutdatedInfoWarning: false

flowchartDiagrams:
  enable: false
  options: ""

sequenceDiagrams: 
  enable: false
  options: ""
---

Java 中 CPU 资源分配对象是 Thread，Go 中 CPU 资源分配对象是 goroutine。Java Thread 与系统线程为一一对应关系，goroutine 是 Go 实现的用户级线程，与系统线程是 m:n 关系。

本文「线程」一词兼指 Java Thread 和 goroutine，涉及区别之处，则改用具体名词。

## 线程和任务
### 在线程中运行任务
在 Java 中，如要获得 CPU 资源并异步执行代码单元，需要将代码单元包装成 Runnable，并创建可以运行代码单元的 Thread 并执行 start 方法启动线程。
```java
Runnable task = ()-> System.out.println("task running");
Thread t = new Thread(task);
t.start();
```
Java 应用一般使用线程池集中处理任务，以避免线程反复创建回收带来的开销。
```java
Runnable task = ()-> System.out.println("task running");
Executor executor = Executors.newCachedThreadPool();
executor.execute(task);
```

在 Go 中，则需要将代码包装成函数。使用 `go` 关键字调用函数之后，便创建了一个可以运行代码单元的 goroutine。一旦 CPU 资源就绪，对应的代码单元便会在 goroutine 中执行。
```go
go func() {
  fmt.Println("task running")
}()
```
**Java 和 Go 的一个显著区别是：Java 官方库提供了强大的线程池（Executor 及 ExecutorService 接口实现）实施线程复用和线程管理，goroutine 则可以不断被创建和销毁，不需要任何显式管理（实际上应用也无法获取 goroutine 引用）。**

### 定时任务和延时任务

Java 使用 ScheduledExecutorService 
```java
public static void main(String[] args) throws InterruptedException {
  ScheduledExecutorService schExecutor = Executors.newSingleThreadScheduledExecutor();
  Runnable task = () -> System.out.println("tick  at " + LocalDateTime.now().getSecond());
  schExecutor.scheduleAtFixedRate(task, 1, 1  , TimeUnit.SECONDS);
  Thread.sleep(3000);
  schExecutor.shutdown();
}
```

Go 使用 time channel
```go
func main() {
  go func() {
    ticker := time.Tick(time.Second)
    time.Sleep(time.Second)
    for {
      <-ticker
      fmt.Printf("tick at %d\n", time.Now().Second())
    }
  }()
  time.Sleep(3 * time.Second)
}
```
两门语言均可得到类似输出
```
tick at 27
tick at 28
tick at 29
```

定时任务和延时任务是类似的，这里只展示带有延时的定时任务，一次性延时任务，Java 可以使用 schedule，Go 去掉 for 循环即可。

### async-callback ?
Java async-callback 模式一般基于 Future 拓展，8 之后加入的 CompletableFuture 提供了非常强大的 callback 支持，8 之前可以使用 Guava 库提供的 ListenableFuture。
```java
static CompletableFuture<String> asyncJob() {
    return CompletableFuture.supplyAsync(() -> {
        // some expensive job...
        return "finish";
    });
}

public static void main(String[] args) throws Exception {
  // 运行异步任务并注册回调
  asyncJob().whenComplete((ret, ex) -> {
      if (ex != null) {
          // 处理异常
      }
      // 处理运行结果
  });
}
```

Go 并没有明显的 async-callback，如果需要用到类似 Future/Promise 之类的地方，应该使用 channel 替代。Go 代码不会有明显的同步、异步差别，请忘记回调。

```go
type ResultErr struct {
  ret string
  err error
}

func asyncJob() <-chan ResultErr {
  retErr := make(chan ResultErr)
  go func() {
    // do expensive job
    // 如果中途发生异常，返回错误
    // retErr <- ResultErr{err: errors.New("error")}
    retErr <- ResultErr{ret: "finish"}
  }()
  return retErr
}

func main () {
  retErr := <-asyncJob()
  if retErr.err != nil {
    // 错误处理
  }
  // 结果处理
  // ret := retErr.ret
}
```
### 等待任意任务完成，批量执行任务
Java 线程池 ExecutorService 提供了 2 个便捷的方法 invokeAny 和 invokeAll。invokeAny 表示并发执行一组任务，执行速度最快任务的结果将被返回。invokeAll 表示并发执行一组任务，所以执行结果以 Future 数组返回。

```java
// ExecutorService

<T> T invokeAny(Collection<? extends Callable<T>> tasks)
        throws InterruptedException, ExecutionException;

<T> List<Future<T>> invokeAll(Collection<? extends Callable<T>> tasks)
      throws InterruptedException;
```

Go 很容易实现 invokeAny，只要创建一个 buffered channel 接收结果，创建一个 buffered channel 通知取消，同时创建一组 goroutine 执行任务。每个 goroutine 先检测是否有取消信号，如果有则直接结束，否则走默认路径执行任务，完成后往  buffered channel 写结果。

调度方只要在接收到最快结果后通知取消即可。

```go
func invokeAny() {
	ctx, cancel := context.WithCancel(context.Background())
  defer cancel()
  retChan := make(chan string)

  for i := 0; i < 10; i++ {
    go func() {
      // execute job
      ret := do()
      select {
      case <-ctx.Done():
        return
      default:
        retChan <- ret
      }
    }()
  }

  // Wait for the first result
  firstRet := <-retChan
  fmt.Println(firstRet)
  cancel() // Cancel other requests
}
```

invokeAll 简单场景非常类似之前使用 RetErr channel 模拟 Future 的情况，改为 channel slice 即可，这里不再展示。

复杂场景建议使用拓展库提供的 [x/sync/errgroup.Group]。

### thread-local storage ?
Java ThreadLocal 类支持 thread-local storage，合理利用 ThreadLocal 可以有效减少锁争用，提高并发度。下面代码展示了 ThreadLocal 的线程独立性，main Thread 无法获取新起 Thread 写入的值，新起 Thread 也无法读取 main Thread 写入的值，且写入互不干扰。

```java
private static final ThreadLocal<String> localMap = new ThreadLocal<>();
public static void main(String[] args) throws Exception {
  localMap.set("main hello");
  Thread t = new Thread(() -> {
      String tName = Thread.currentThread().getName();
      System.out.println(tName + " get " + localMap.get());
      localMap.set("sub hello");
      System.out.println(tName + " get " + localMap.get());
  });
  t.start();
  t.join();
  System.out.println("Thread-main get "+ localMap.get());
} //～
Thread-0 get null
Thread-0 get sub hello
Thread-main get main hello
```
goroutine 并不支持本地存储，如果需传递上下文信息（比如链路追踪），可以使用 Context 接口，将其作为方法参数显式传递

```go
func main() {
  ctx := context.WithValue(context.TODO(), "key", "value")
  withCtx := func(ctx context.Context, others ...int) {
    fmt.Println(ctx.Value("key"))
  }
  go withCtx(ctx, 1, 2, 3)
  time.Sleep(time.Millisecond)
} //~
value
```

### 任务中止
Java 和 Go 应用层任务中止，一般均使用协同式中止。

Java 任务代码块需在每次循环前检查当前线程 interrupt 标志是否被设置，如果被设置则中止循环。一般可以通过 Thread 或者 Future 发起。

注：目前 Java 仍可使用 stop 方法强行中止线程，但官方库在 1.2 时就已将该方法标注为 Deprecated。这种方式会导致线程立刻停止运行并释放所有 monitor，导致其他线程看到不一致的状态，容易引发严重的业务问题。

```java
public class CancelableTask {
  public static void main(String[] args) throws InterruptedException {
    interruptThread();
    interruptFuture();
  }

  static void interruptThread() throws InterruptedException {
    Thread t = new Thread(CancelableTask::loop);
    t.start();
    Thread.sleep(1);
    t.interrupt();
  }

  static void interruptFuture() throws InterruptedException {
    ExecutorService exeSvc = Executors.newSingleThreadExecutor();
    Future<?> ft = exeSvc.submit(CancelableTask::loop);
    Thread.sleep(1);
    ft.cancel(true);
    exeSvc.shutdown();
  }

  static void loop() {
    while (!Thread.interrupted()) {
        //... do business
        System.out.println("looping");
    }
    System.out.println("stopped");
  }
}
```
Go 任务代码块可以依靠检查 select 关键字在每一轮循环检查 stop channel 是否有信号送达，如果没有则继续循环任务，如有则停止循环并返回。

```go
func main() {
  stop := make(chan struct{})
  go loop(stop)
  <- time.After(time.Millisecond)
  close(stop) // 也可使用 stop <- struct{}{}
}

func loop(stop <-chan struct{}) {
  for {
    select {
    case <-stop:
      fmt.Println("stopped")
      return
    default:
      //do business
      fmt.Println("looping")
    }
  }
}
```
两种语言均会得到以下输出结果
```
looping
...
looping
stopped
```
Java 能不能用 BlockQueue 做类似事情？答案是可以，但 BlockQueue 占用内存太大，不适合作为状态同步工具。更主要原因是，BlockQueue 对于 Java 而言只是一个库实现，缺乏编译器和运行时支持，channel 对于 Go 而言是同步原语，有非常好的编译器和运行时支持。
```java
static void loopWithBlockQueue(BlockingQueue<Object> queue) {
    while (queue.poll() == null){
        //... do business
        System.out.println("looping");
    }
    System.out.println("stopped");
}

public static void main(String[] args) throws InterruptedException {
    BlockingQueue<Object> queue = new ArrayBlockingQueue<>(1);
    new Thread(() -> loopWithBlockQueue(queue)).start();
    Thread.sleep(1);
    queue.put(new Object());
}
```
Go 另一种常用的取消方式是使用 Context 接口
```go
func main() {
  ctx, cancel := context.WithCancel(context.TODO())
  go func(ctx context.Context) {
    time.Sleep(time.Millisecond)
    select {
    case <-ctx.Done():
      fmt.Println("task canceled")
    default:
      fmt.Println("running")
      // do business
    }
  }(ctx)
  cancel()
  time.Sleep(2 * time.Millisecond)
}//~
task canceled
```
Context 除支持直接取消外，还支持超时取消 (WithDeadline，WithTimeout)。

### 优雅停机
优雅停机的思路一般都较为类似：先改状态为停机，接收函数停止接收任务，等待任务队列排空后退出进程。

Java 应用优雅停机一般只需做前 2 步即可，第 3 步通常利用线程池完成（shutdown，awaitTermination）。

上文提到，Go 并没有线程池概念，但利用 WaitGroup 实现优雅停机非常简单，见如下代码：

* 接收任务时，先检查 stop channnel 是否关闭，如果关闭则拒绝任务，反之WaitGroup 加 1 并新建 goroutine 执行任务，执行完成后，WaitGroup 减 1。
* 停机时，关闭 stop channel，随后调用 WaitGroup Wait 等待所有任务完成。

```go
var wg = sync.WaitGroup{}
var stop = make(chan struct{})

func accept(task func()) error {
  select {
  case <-stop:
    return errors.New("reject")
  default:
    wg.Add(1)
    go func() {
      defer wg.Done()
      handle(task)
    }()
    return nil
  }
}

func handle(task func()) {
  task()
}

func shutdown() {
  close(stop)
  wg.Wait()
}
```

## 变量同步原语
下表列出了 Java 和 Go 官方库中同步方式的对应关系，切记这只是一种粗略的对应关系，因为两者有着不同的并发哲学。

|            |Java                                 |Go               |
|------------|------------------------------------ |------------------|
|锁          |synchronized, ReentrantLock          |sync.Mutex, one unit buffered channel |
|读写锁       |ReentrantReadWriteLock, StampedLock  |sync.RWMutex            |
|条件变量     |Condition                            |sync.Cond               |
|信号量       |Semaphore                            |buffered channel, x/sync/semaphore.Weighted |
|CAS/Atomic  |Varhandle、volatile，Atomic 类        |atomic.Value，atomic 包  |
|once        |单例模式                              |sync.Once               |
|BSP 模型     |CountDownLatch，CyclicBarrier        |sync.WaitGroup         |

注：BSP 指 [Bulk Synchronous Parallelism]

锁操作皆类似，即在进入关键代码路径时，调用锁定方法，同时保证无论中途是否发生异常，均确保释放方法得到调用。读写锁则是锁分为 2 把子锁分别对应于读路径和写路径的情况。这里不做过多介绍。

### 锁的公平模式与非公平模式
公平模式与非公平模式指的是，锁释放之际，等待队列非空，此时恰好有请求线程尝试获取锁，如果锁是公平模式，请求线程主动在队尾挂起，队头线程获得锁并立刻被唤醒运行；如果锁是非公平模式，请求线程直接获取锁。

非公平模式上下文切换少、吞吐高，但容易造成线程饥饿。

Java ReentrantLock、ReentrantReadWriteLock 锁，支持在构造函数中传递布尔值配置锁的公平性和非公平性。

Go Mutex 不支持配置，但在运行期间自行在公平和非公平之间切换。Go Mutex 默认是非公平模式，如果在非公平模式检测到队尾 goroutine 发生饥饿（等待超过 1ms），会自动切换到公平模式；如果公平模式检测到队尾 goroutine 等待时间小于 1ms，则会且切回非公平模式。

### 锁的可重入支持 ?
Java synchronized 和带有 Reentrant 前缀的锁实现都能保护关键代码路径，同时支持可重入

```java
public class Locker {
  public static void main(String[] args) {
      synchronized (Locker.class) {
          reentrant();
          synchronized (Lock.class){
              reentrant();
          }
      }
      System.out.println();
      ReentrantLock lock = new ReentrantLock();
      lock.lock();
      reentrant();
      lock.lock();
      reentrant();
      lock.unlock();
      lock.unlock();
  }

  static void reentrant() {
      System.out.println("entered");
  }
}//~
entered
entered

entered
entered
```
Go 官方库没有提供任何可重入锁实现，sync.Mutex，sync.RWMutex 均不支持可重入，类似这种操作会导致死锁
```
mu := sync.Mutex{}
mu.Lock() // ok
mu.Lock() // dead lock
```
遇到「可重入场景」，一般建议是将方法拆为公开版本和私有版本，公开方法加锁，私有方法不加锁，细节讨论参见 [6]。

### 锁的可中断式获取和超时获取
Java 官方库的锁实现通常都支持可中断式获取和超时获取，查看 Lock 接口可以发现，lock、unlock 方法支持阻塞时获取，lockInterruptibly 支持中断式获取，tryLock 支持尝试性获取和超时获取。

中断式获取操作上和上文展示的任务中断类似，如果 A 线程阻塞于取锁，B 线程代码调用 A 线程 interrupt 方法后，被挂起的 A 线程会从在随后恢复运行并抛出 InterruptedException 异常。
```
public interface Lock {
    void lock();
    
    void unlock();

    void lockInterruptibly() throws InterruptedException;

    boolean tryLock();

    boolean tryLock(long time, TimeUnit unit) throws InterruptedException;
}
```
以下代码展示了 Java 可中断式获取和超时获取
```java
public static void main(String[] args) throws InterruptedException {
  ReentrantLock lock = new ReentrantLock();
  lock.lock();
  Thread t = new Thread(() -> {
      try {
          // 中断式获取，被中断抛出 InterruptedException
          // lock.lockInterruptibly();
          // 超时获取，操作超时自动返回，被中断抛出 InterruptedException
          lock.tryLock(10, TimeUnit.MILLISECONDS);
      } catch (InterruptedException ex) {
          ex.printStackTrace();
      }
  });
  t.start();
  Thread.sleep(100);
  t.interrupt();
}//~
java.lang.InterruptedException
  at java.base/java.util.concurrent.locks.AbstractQueuedSynchronizer.tryAcquireNanos(AbstractQueuedSynchronizer.java:992)
  at java.base/java.util.concurrent.locks.ReentrantLock$Sync.tryLockNanos(ReentrantLock.java:168)
  at java.base/java.util.concurrent.locks.ReentrantLock.tryLock(ReentrantLock.java:479)
  ...
```

Go sync.Mutex 并不支持可中断式获取和超时获取，因为这类场景应该使用 channel 实现，下面代码使用长度为 1 的 buffered channel 展示了这种技巧

```go
var lockCh = make(chan struct{}, 1)

func TryLock(timeout time.Duration) bool {
  for {
    select {
    case lockCh <- struct{}{}:
      return true
    case <-time.After(timeout):
      return false
    }
  }
}

func LockInterruptibly(interrupt <-chan struct{}) bool {
   for {
    select {
    case <-interrupt:
      return false
    case lockCh <- struct{}{}:
      return true
    }
  }
}

func UnLock() {
  <-lockCh
}
```

### 条件变量
一般来说，条件变量衍生于锁，不同条件变量只是同一锁空间下的不同等待队列。这点 Java 和 Go 类似。

Java 可以使用 synchronized 代码块保护特定代码路径，兼而可以在 synchronized 代码块中使用 Object wait 和 notify、notifyall 方法实现单一条件等待。如果需要多个条件，可以使用官方库提供的 Lock 实现和 Condition 实现。

Java 创建条件变量的方式是调用 Lock 接口 newCondition 方法。

Go sync.Cond 结构体需设置 sync.Mutex 字段才能工作，挂起方法为 Wait，唤醒方法为 Braodcast。

### 信号量
Java 官方库 Semaphore 类实现了信号量机制
```
Semaphore semaphore = new Semaphore(5);
semaphore.acquire(1);
semaphore.release(1);
```

Go 官方库并没有提供 Semaphore 实现，拓展库提供了信号量实现 [x/sync/semaphore.Weighted]。不过，类似上面非阻塞锁和超时锁，同样可以使用 buffered channel 模拟之，一个简单的实现如下

```go
type Semaphore struct {
  permits chan struct{}
}

func NewSemaphore(permits uint) *Semaphore {
  permitsCh := make(chan struct{}, permits)
  return &Semaphore{permits: permitsCh}
}

func (s *Semaphore) Acquire() {
  s.permits <- struct{}{}
}

func (s *Semaphore) Release() {
  <-s.permits
}
```

### CAS/Atomic
Java 和 Go 均支持 CAS 及原子操作。

Java 的 CAS 操作由 volatile 关键字和 VarHandle（9 之前是 UnSafe）支持，在此基础上有了 Atomic 类和并发包中的大量无锁实现（如 ConcurrentHashMap, AQS 队列等）。

Go atomic.Value 提供了 CAS 操作基础，它保证任意类型（interface {}) 的 Load 和 Store 为原子操作，在此基础上有 atomic 包。

### Once 与单例模式
Go sync.Once 常见用途是懒加载，它有 2 个特性
1. 保证程序运行期间某段代码只会执行一次
2. 如果多个 goroutine 同时执行 Once 守护代码，只有 1 个 goroutine 会获得执行机会，其他 goroutine 会阻塞直至代码执行完毕

```go
func main() {
  var once = sync.Once{}
  f := func() {
    time.Sleep(10 * time.Millisecond)
    fmt.Println("do once")
  }
  go func() {
    fmt.Println("do once start")
    once.Do(f)
    fmt.Println("do once finish")
  }()
  time.Sleep(1 * time.Millisecond)
  for i := 0; i < 2; i++ {
    go func() {
      fmt.Println("block...")
      once.Do(f)
      fmt.Println("resume")
    }()
  }
  time.Sleep(10 * time.Millisecond)
}//~
do once start
block...
block...
do once
do once finish
resume
resume
```

Java 较为接近这种需求的场景是懒加载单例模式，如
* 双重检查单例模式
* 静态内部类单例模式
* 枚举单例模式

如要获取一致的语义只需将对象创建改为 Runnable 执行即可。

### BSP 模型
BSP 原语支持等待一组执行线程完成，等待线程和执行可以在完成点同步线程本地计算结果，然后继续下一步操作。以如下场景为例：
1. 主线程向多个后台服务同时发起 HTTP 请求，主线程需等待其他线程返回后，才能继续执行
2. 反复执行类 Map-Reduce 计算，每轮 Map 完成后在同步点执行 Reduce 操作，之后开始下一轮计算

在 Java 中，BSP 原语分为 CountDownLatch 和 CyclicBarrier 两种实现，两者均须在构造函数指定执行任务数量。CountDownLatch 仅支持一次性同步，执行线程调用 countdown 表示计算完成，等待线程调用 await 等待所有计算完成，所有计算完成后，调用 await 会立即返回（场景 1）。CyclicBarrier 支持多次同步，可以在 await 返回后调用 reset 方法恢复计数（场景 2）。

Go BSP 原语统一由 sync.WaitGroup 支持，sync.WaitGroup 支持 Done 方法表示执行完成，Add 方法表示添加任务，Wait 方法表示等待所有任务完成。

```go
func main () {
  wg := sync.WaitGroup{}
  wg.Add(3)

  for i := 0; i < 3; i++ {
    ii := i
    go func() {
      defer wg.Done()
      fmt.Printf("%d finished\n", ii)
    }()
  }

  wg.Wait()
  fmt.Println("all finish")
  // do exchange
} // ~
2 finished
0 finished
1 finished
all finish
```

## 内存模型
内存模型指的是，Java 和 Go 之类的高级语言（相对 C）在各自语言层面实现的多线程内存同步规范。这些同步规范保证了多线程并发进入某一代码路径时，相应的读取和写入能按照预期的顺序发生。实现上，多采用禁止编译器重排指令和使用硬件指令强制同步缓存和主存（又称内存屏障）。下面仅在语言使用者而非语言开发者的角度讨论如何理解和应用内存模型，也即如何在边界内写好并发程序。
 
注：下文描述「t2 时刻 线程 B 对 V 执行读取操作，线程 A 在 t1 时刻之前发生的所有写入均对线程 B 可见」与 `happened-before`、`happens-before` 等价，隐藏着一层含义是，语言编译器和运行时会禁止指令排，即保证在 t1 时刻不会有任何写入/读取操作被重排到 t1 之后，t2 时刻保证不会有任何写入/读取被重排到 t2 之前。

### Java volatile
线程 A 对 volatile 修饰变量 V 执行写入操作后（t1 时刻），随后若任意线程 B 对 V 执行读取操作（t2 时刻，t2 < t1），则线程 A 在 t1 时刻之前发生的所有写入均对 B 可见。

Java 官方库 Lock 实现就利用了 volatile 语义：锁释放和锁获取分别对应 volatile 写和读，这样先发线程对受保护变量的写入就能顺利同步到后发线程。Atomic 类也是如此，先发尝试将更新 CAS 到 volatile 字段，后发线程立马能读取到最新值。

### Java synchronized
线程 A 在 t1 时刻释放 JVM 锁后（monitor exit)，在随后的 t2 时刻，若任意线程 B 获取到 JVM 锁（monintor enter），则线程 A 在 t1 时刻之前发生的所有写入均对 B 可见。

synchronized 是 JVM 内置锁实现，写入 volatile 变量相当于 monitor exit，读取 volatile 变量相当于 monintor enter。

### Go Mutex
Go 并未像 Java 一样提供 volatile 这样基础的关键字，但其 Mutex 相关内存模型和 synchronized 或 Java 官方库 Lock 实现有十分接近语义。

若 goroutine A 在 t1 时刻释放 sync.Mutex 或 sync.RWMutex 后，在随后的 t2 时刻，若任意 goroutine B 获取到锁，则 goroutine A 在 t1 时刻之前发生的所有写入均对 B 可见。

### Go Once

假设 Once 守护方法为 f()，那么发生在 f() 中所有写入对所有执行 once.Do(f) 返回后的 goroutine 可见。

Go sync.Once 实现方式其实为 Mutex 和 CAS，根据上面关于 Mutex 和 Once 功能不断理解其原理，获取到执行权的 goroutine 执行完 f() 后，会解锁 Mutex，未争取到执行权的其他 goroutine 则会在后续陆续获取锁并释放锁，所以有以上保证。

### Java final
如果某个对象类字段由 final 修饰，则线程 A 通过构造函数对该字段的赋值对后续所有线程可见，无需任何同步操作。

Java 对象构造由 2 阶段组成，1 阶段为分配对象内存并 0 值化，2 阶段为调用构造函数执行字段初始化。如果 A 线程正执行对象构造 ，那么 B 线程在 1-2 阶段之间获取到对象引用并尝试进行字段读取，如果对应字段未由 final 修饰，那么便会出现不一致情况。

### Go init
Go 基础启动初始化的规范，比较简单直白：
* 初始化默认在单 goroutine 中执行，但是该 goroutine 在中途可能会创建其他 goroutine 执行并发初始化。
* 如果 package p 引用了 package q，那么 q 中的所有 init functions 的执行完成时间发生在 p 中任意 init functions 开始执行前。
* main 包的 main 函数在所有 init functions 执行完成之后执行。

### Java Thread
如果 Thread A 启动 Thread B（t 时刻），则 Thread A 发生在 t 时刻之前的所有写入对 Thread B 可见。

如果 Thread A join Thread B（t 时刻），则 Thread B 发生在 t 时刻之前所有写入对 Thread A 可见。

### goroutine

如果 goroutine A 启动 goroutine B（t 时刻），则 goroutine A 发生在 t 时刻之前的所有写入对 goroutine B 可见。

反之，goroutine 退出并不附带内存同步操作。

如下代码中，调用 hello 必然打印 hello, 调用 notHello 则不一定打印 hello。
```go
var a string

func hello() {
  a = "hello"
  go func() { print(a) }()
}

func notHello(){
  go func() { a = "hello" }()
	print(a)
}
```

### chanel
1. goroutine A 对 channel C 执行发送操作或关闭操作后（t1 时刻），如果任意 goroutine B 对 channel C 执行对应接收操作（t2 时刻，t2 < t1 或 t1 > t2），则 goroutine A 在 t1 时刻之前发生所有的写入均对 goroutine B 可见。

2. 对于长度为 0 的 unbuffered channel C，有一条更特殊的规则，如果 goroutine A 对 C 执行接收操作（t1 时刻），若任意 goroutine B 对 channel C 执行发送操作（t2 时刻，t2 可以大于或者小于 t1），则 t2 之后，goroutine A 在 t1 时刻之前发生所有的写入均对 goroutine B 可见。

3. 对于长度为 n（n > 0) 的 buffered channel C，如果 goroutine A 对 C 执行第 k 次接收操作（t1 时刻），若任意 goroutine B 对 channel C 执行第 n + k 次发送操作（t2 时刻，t2 可以大于或者小于 t1），则 t2 之后，goroutine A 在 t1 时刻之前发生所有的写入均对 goroutine B 可见。

Go channel 在语言层面是一种语法糖，无论是底层类似 Java ArrayBlockQueue，发送和接收并发由 sync.Mutex 守护。

第 1 条规则很容易理解，写入的释放锁操作发生在接收的加锁操作之前。

第 2 条规则也好理解，因为接收端的锁释放操作在发送端的加锁操作之前。注意不要用 Java SynchronousQueue 类比 unbuffered channel，前者只是基于 CAS，并没有这种保障。

第 3 条规则其实可以是按第 2 条推导而来，对于长度为 n 的 channel，第 n + k 次发送加锁操作必然发生在第 k 次接收释放锁操作之后。

## 总结

Java 开放了非常底层的内存模型，官方库在此基础上提供了丰富强大的并发工具。这种并发哲学，一方面留下了巨大的性能优化空间，另一方面则加大了编程难度，以任务中断为例，线程的 interrupt 状态便是一个不易理解的概念。这也导致了开发 Java 应用便离不开各种三方框架，新手 Java 程序员可能需要在各种别人写好的代码中摸爬滚打好些年，才能收发自如优化应用性能。

Go 提供的内存模型则相对高层，最底层的 Mutex 和 channel 在 Java 中可以对应到 Lock 层。另外，Go 为 channel 提供了简洁优雅的语法糖，Go 为 channel 提供了 select、range 等关键字特性，Go 不允许应用获取 goroutine 引用，Go 不提供 thread-local 存储，等等。这一切组合起来，产生了非常简单健壮的并发哲学。我在上文多处展示过，许多 Java 中需要相当技巧和代码才能实现的并发同步操作，Go 只需很少的代码就实现了。

同时可以发现，Go sync 包提供的能力极为有限，且很多需要用锁的场景，用 channel 可以做得更简单易懂。这与 Go 相对年轻，且同时提倡 [CSP] 并发模型有关。[Go 编程箴言] 第一条 `Don't communicate by sharing memory, share memory by communicating` ，即提倡使用 channel 作为线程同步手段。

Java 平台中与 Go 并发哲学相似的是基于 [Actor] 并发模型的 [Akka] 和 [Vert.x]，不过类库实现的并发模型肯定不如语言级的并发模型简易好用。

Java Thread 背后是系统线程，goroutine 是用户态线程，这带来了巨大的资源占用和切换速度差异：
* Java Thread 用户 stack 默认占用 1 MB，内核 stack 占用 8 KB [[1]]，而 goroutine stack 起始大小仅为 2 KB 并支持动态扩展 [[2]]
* Java Thread 由操作系统内核调度，切换时间通常在 2000 ns 往上，goroutine 由 Go 运行时调度器切换，耗时在 170 ns 左右，后者比前者快 10 倍以上 [[3]]

在 Go 中，goroutine 则可以频繁被创建和销毁，不需要任何显式管理。Java 应用一般会使用标准库线程池以实现线程复用和线程管理。

为减少上下文切换开销，Java 应用可以利用 async-callback 模型减少上下文切换开销，标准库 CompletableFuture（8 之后）、google Guava 库 ListenableFuture [[4]] 均提供了非常好的 async-callback 模型。

反观 Go，因为 goroutine 切换速度极快，所以不需要 async-callback 模型，select channel 之类的阻塞切换代码往往随处可见。以 Go 标准库为例，凡涉及系统调用，就会通过运行时调度器将调用方 goroutine 挂起并把 CPU 资源出让给其他 goroutine，系统调用返回之后，因阻塞挂起的 goroutine 会被重新调度，接着恢复运行，整个过程在调用方看来完全是同步的。

所以 Bob Nystrom 在他的博客中说，Go 消灭了同步和异步的区别 [[5]]
> Go has eliminated the distinction between synchronous and asynchronous code.

## 延伸阅读
* [go-hits-the-concurrency-nail-right-on-the-head](https://eli.thegreenplace.net/2018/go-hits-the-concurrency-nail-right-on-the-head)
* [Go 内存模型](https://golang.org/ref/mem)
* [Java 内存模型](https://en.wikipedia.org/wiki/Java_memory_model)

[x/sync/semaphore.Weighted]: https://github.com/golang/sync/blob/master/semaphore/semaphore.go
[x/sync/errgroup.Group]: https://github.com/golang/sync/blob/master/errgroup/errgroup.go
[Bulk Synchronous Parallelism]: https://en.wikipedia.org/wiki/Bulk_synchronous_parallel

[1]: https://www.kernel.org/doc/html/latest/x86/kernel-stacks.html
[2]: https://golang.org/src/runtime/stack.go?h=StackMin#L72
[3]: https://eli.thegreenplace.net/2018/measuring-context-switching-and-memory-overheads-for-linux-threads/
[4]: https://github.com/google/guava/blob/master/guava/src/com/google/common/util/concurrent/ListenableFuture.java
[5]: http://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/
[6]: https://stackoverflow.com/questions/14670979/recursive-locking-in-go

[Go 编程箴言]: https://go-proverbs.github.io/
[CSP]: https://en.wikipedia.org/wiki/Communicating_sequential_processes
[Actor]: https://en.wikipedia.org/wiki/Actor_model
[Vert.x]: https://vertx.io/
[Akka]: https://akka.io/