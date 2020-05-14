---
title: "正则组匹配"
date: 2019-05-09T00:34:10+08:00
lastmod: 2019-05-09T00:50:10+08:00
draft: false
keywords: ["Regex","Java","Go"]
description: ""
tags: ["Regex","Java","Go"]
author: "Zeng Xu"
summary: "Regex group puzzles"

comment: false
toc: false
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

分组 (group) 和 捕获 (capture) 是正则中的常用概念，以表达式 `([a-z]+)(([0-9]+)([a-z]+))` 为例，被括号包起来的每一个子表达式 `(...)` 都为组，如这里的 `[a-z]+`、 `[0-9]+`和`[a-z]+`。发生匹配之后，对应的匹配文本便是捕获组（captured group)。

在 Java 中，该表达式每完成一次匹配，都会产生 4 个捕获组，下面的代码展示了输入长度为 20 的字符串 `aaa123ccc/aaa123ccc/` 的情况：

```java
Pattern p = Pattern.compile("([a-z]+)([0-9]+)([a-z]+)");
Matcher m = p.matcher("aaa123ccc/aaa123ccc/");

while (m.find()){
    for(int i=0;i<=m.groupCount();i++){
        System.out.printf("group %d [%d,%d] : %s\n", i,m.start(i), m.end(i) ,m.group(i));
    }
}
//～
group 0 [0,9] : aaa123ccc
group 1 [0,3] : aaa
group 2 [3,6] : 123
group 3 [6,9] : ccc
group 0 [10,19] : aaa123ccc
group 1 [10,13] : aaa
group 2 [13,16] : 123
group 3 [16,19] : ccc
```
容易知道，0 号捕获组为整个表达式，余下则按照左括号出现的顺序编号。

在正则环境中，Java 可通过 `$1`、`$2` 引用对应的 capture group，Go 使用 `${1}`、`${2}`。如，我们将整个匹配文本替换某几个特定捕获组和特殊字符的组合并作为结果返回
```go
pattern := regexp.MustCompile("([a-z]+)(([0-9]+)([a-z]+))")
out := pattern.ReplaceAllString("aaa123ccc/","${3}special${4}");
fmt.Println(out) 
//~
123specialccc/
``` 

## 分组别名

可使用格式 `(?<Name>...)` 对分组取名，方便在 replace 函数中引用，比如我们要获取日期 `2019-05-09` 中的年。

Java 可以这么做
```java
Pattern p = Pattern.compile("(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})");
Matcher m = p.matcher("2019-05-09");

if (m.find()){
    String out = m.replaceFirst("${year}");
    System.out.println(out);
}
//~
2019
```

Go 则需使用格式 `(?P<Name>...)`

```go
pattern := regexp.MustCompile("(?P<year>\\d{4})-(?P<month>\\d{2})-(?P<day>\\d{2})")
out := pattern.ReplaceAllString("2019-05-09", "${year}")
fmt.Println(out)
//~
2019
```

别名可以提高正则可读性。

## replace captured group

但通常，我们实际只需要针对特定 sub captured group 进行，有趣的是，无论是 Java(8)，还是 Go 提供的 replace 接口，都不能通过非常直观都方式进行，你必须反着来。

比如，下面的 Go 代码展示如何将 `aaa` 替换为 `%`，实际是在每一次匹配中将 group 0 替换为了 group 2 和字符 % 的组合，并不是直接替换 group 1。

```go
pattern := regexp.MustCompile("([a-z]+)(([0-9]+)([a-z]+))")
out := pattern.ReplaceAllString("aaa123ccc/aaa123ccc","%${2}")
//~
%123ccc/%123ccc
```
Java 代码如下
```java
Matcher m = Pattern.compile("([a-z]+)(([0-9]+)([a-z]+))")
                .matcher("aaa123ccc/aaa123ccc");
m.replaceAll("%$2");
```

为什么这样设计呢，主要是，如果 replace 支持声明删除某个 sub group，原有的 `$1`、`${1}` 势必要引入额外的标识，额外的语法会带来更大的使用负担；其次在 replace 的接口中声明去掉某个东西其实很奇怪。。。

如果非要针对特定 sub captured group 做替换，可以写代码自己实现，毕竟捕获组结果其实只是一个字符串 index 集合而已，使用 Java 或者 Go 中的工具按照 index 替换即可。

```go
func TestReplace(t *testing.T) {
  ret := replaceGroup("([a-z]+)(([0-9]+)([a-z]+))", "aaa123ccc/aaa123ccc",
    "%", 1, 2)
  fmt.Println(ret)
  //~
  %123ccc/%123ccc
}

func replaceGroup(regex, input, replace string,
  groupToReplace, groupOccurrence int) string {

  pattern := regexp.MustCompile(regex)
  indexes := pattern.FindAllStringSubmatchIndex(input, 4)

  fmt.Printf("%v\n", indexes) //捕获组结果， [[0 9 0 3 3 9 3 6 6 9] [10 19 10 13 13 19 13 16 16 19]]

  // 如果要替换所有可以去掉 if 判断
  // 同时  strings.Replace 最后一个参数传 -1
  if indexes == nil || len(indexes) < groupOccurrence {
    return input
  }
  
  idx := groupToReplace * 2

  return strings.Replace(input, input[indexes[0][idx]:indexes[0][idx+1]], replace, 2)
}
```
关于 Java，可以使用 [这里第二个答案](https://stackoverflow.com/questions/988655/can-i-replace-groups-in-java-regex) 提供的实现。

## **(?:...) non-capturing group**

即匹配后不计入 match 编号集合，匹配后不能使用 `$1`, `$2` 引用。

这种模式通常用来表达重复某种模式多次，例如
```
(?:foo)*
(?:foo){3,}//重复出现 3 次以上
```

### **(?>...)** non-backtracking group (atomic group)

atomic group 是 non-capturing group 的一种。

提示正则引擎，一旦该 group 匹配完成，游标不再回溯。如下面的例子所示，`a(?>bc|b)c` 只能匹配 `abcc` 而不能匹配 `abc`

```java
Pattern p = Pattern.compile("a(?>bc|b)c");

Matcher m =p.matcher("abc");
if(!m.find()) System.out.println("not match");

m = p.matcher("abcc");
if(m.find()) System.out.println("matched");
//～
not match
matched
```

假设我们需要判断单词 `ints` 是否为 int、string 或者 intstring 其中一个，group 可以这样写 `\b(int|string|intstring)\b`，这是引擎会先判断 `ints` 不是 `int`，再判断 `ints` 不是 `string`，再判断 `ints` 不是 `intstring`，然后才断定不匹配。

如果改为 atomic group `\b(?>int|string|intstring)\b`，引擎直接将 `ints` 匹配到 `int` 后，再往后发现还存在 s 字符，直接就会断定不匹配。

很多文章提到，atomic group 作用是提升正则引擎性能。不过笔者在 Java 环境中 benchmark 时发现，对于很多较短的文本匹配，atomic group 相较普通 non-capturing group， 并没有带来多少提升，甚至导致匹配变慢。

reference
* https://www.regular-expressions.info/atomic.html
* https://stackoverflow.com/questions/14411818/confusion-with-atomic-grouping-how-it-differs-from-the-grouping-in-regular-exp
* https://stackoverflow.com/questions/26093501/atomic-groups-clarity


## LookAround group

注：Java 支持所有语法，go(截至 1.14) 不支持任何 LookAround group ([查看支持情况](https://github.com/google/re2/wiki/Syntax))

> [LookAround 语义](https://stackoverflow.com/questions/406230/regular-expression-to-match-a-line-that-doesnt-contain-a-word)
>
> Look-arounds are also called zero-width-assertions because they don't consume any characters. They only assert/validate something.

**(?=...)** Lookahead、**(?!...)** Negative Lookahead

`(?=...)` 表示当前位置后面紧跟着某个 group 则匹配，`(?!...)` 反之，表示后面不跟着什么则匹配

例如，a 后面紧跟着 foo 的情况
```java
Matcher m = Pattern.compile("a(?=foo)(.*)").matcher("afoo");
if (m.find()) System.out.println(m.group());

m = Pattern.compile("a(?=foo)(.*)").matcher("axoo");
if (m.find()) System.out.println(m.group());
else System.out.println("not match");
// afoo
// not match
```

**(?<=...)** Lookbehind、**(?<!...)** Negative Lookbehind

Lookbehind 类相反，是从 group 后一个位置往前看，如果与 group 匹配，则匹配该字符。
与 LookAhead 区别是，group 本身不会被匹配，也即印证了 Around 类语法的属性，只做 assert 而不消费任何字符。

```java
Matcher m = Pattern.compile("(?<=foo)a").matcher("fooa");
if (m.find()) System.out.println(m.group());

m = Pattern.compile("(?<!foo)a").matcher("fooa");
if (m.find()) System.out.println(m.group());
else System.out.println("not found");
// a
// not found
```

## 附 atomic group benchmark 测试结果

按照理论，如需判断 `tracker` 是否在单词集合 `\btra(?:ck|ce|ining|de|in|nsit|ns|uma)\b`，使用 atomic group 应该会有巨大性能提升，实际并不是。

笔者在 Java 8 中分别测试了 100 万、1000 万和 1 亿次匹配，发现两者性能是相当的。

如果你有不同结果或者能解我疑惑，欢迎 email 联系我。

```text
--- benchmark 1000000 times ---
normal group cost: 325 ms
atomic group cost: 296 ms

--- benchmark 10000000 times ---
normal group cost: 2907 ms
atomic group cost: 3002 ms

--- benchmark 100000000 times ---
normal group cost: 29488 ms
atomic group cost: 30854 ms
```

```java
public static void main(String[] args) {
    String in = " tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker " +
            " tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker tracker";

    doBenchmark(1_000_000, in);
    doBenchmark(10_000_000, in);
    doBenchmark(100_000_000, in);
}

public static void doBenchmark(int times, String input){
    System.out.printf("--- benchmark %d times ---\n", times);
    long now = System.currentTimeMillis();
    for(int i=0;i<times;i++){
        benchmarkNormalMatch(input);
    }
    System.out.printf("normal group cost: %d ms\n", System.currentTimeMillis() - now);

    now = System.currentTimeMillis();
    for(int i=0;i<times;i++){
        benchmarkAtomicMatch(input);
    }
    System.out.printf("atomic group cost: %d ms\n", System.currentTimeMillis() - now);
    System.out.println();
}

public static final  Pattern _normal = Pattern.compile("\btra(?:ck|ce|ining|de|in|nsit|ns|uma)\b");
public static void benchmarkNormalMatch(String input){
    Matcher m = _normal.matcher(input);
    while (m.find()){ }
}

public static final  Pattern _atomic = Pattern.compile("\btra(?>ck|ce|ining|de|in|nsit|ns|uma)\b");
public static void benchmarkAtomicMatch(String input){
    Matcher m = _atomic.matcher(input);

    while (m.find()){}
}
```
