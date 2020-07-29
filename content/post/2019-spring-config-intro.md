---
title: "Spring Boot 配置探幽"
date: 2019-06-03T23:56:06+08:00
lastmod: 2019-06-07T23:56:06+08:00
draft: false
keywords: ["spring","spring boot"]
description: "介绍 SpringBoot YAML 和 properties 的对应关系，以及@ConfigurationProperties 和 @Value 的差异"
tags: ["spring","spring boot"]
author: "Zeng Xu"
summary: "介绍 SpringBoot YAML 和 properties 的对应关系，以及 @ConfigurationProperties 与 @Value 差异"

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

> There are myriad flavors of data structures, but they can all be adequately represented with  
> three basic primitives: mappings (hashes/dictionaries), sequences (arrays/lists) and scalars 
> (strings/numbers).

Yaml 官方文档提到，从结构上看，所有的数据（data）最终都可以分解为标量（scalar）、序列（sequence）和映射（mapping）。本文将从这种视野触发，探究 Spring Boot KV 配置与 YAML 配置的转换以及运行绑定涉及的一些细节。

## YAML 和 properties 的对应关系 
SpringBoot 允许应用灵活选择或者混用 YAML 配置文件（application.yaml|yml）和 properties 配置文件 (application.properties)。 

properties 表达形式为 KV，YAML 是 JSON 子集，前者的表达的表达范围大于后者。配置较多时，properties 远不如 YAML 直观。个人觉得 properties 超过一屏幕是灾难。

在 Spring Boot 中，两者在大部分情况下可以互相转换。运行期间，所有配置均会被转换为 KV 格式存储在 Environment 中。

### 标量 (scalar) 对应关系
标量在 Java 语言中最终体现为 String 和 char, boolean, byte, short, int, long, float, double 及其对应包装类。

```
# yaml
spring:
  yaml:
    property: value
---    
# properties 
spring.yaml.property = value
```
### 序列（sequence）对应关系

---
序列在 Java 中体现为 List, Set, Array。

值得一提的是，Spring Boot 运行期间以 key[idx] 形式存储序列配置各元素，所以也可以以 properties 风格逐个声明序列元素。
```
# yaml 风格
sequenceOne: ["a","b","c"]

sequenceTwo:
  - 1
  - 2
---
# properties 风格
sequenceOne[0]=a
sequenceOne[1]=b
sequenceOne[2]=c

sequenceTwo[0]=1
sequenceTwo[1]=2
```
### 映射（mapping）对应关系
---
映射一般可以表现为两种 Java 对象，一种是 Map 对象，另外一种是 POJO 对象。
1. Map
```
Map<String, String> map;
Map<String, Map<String, String>> mapInMap;
---
# yaml 风格
map:
  key1: value1
  key2: value2
  mapInMap:
    key3: value3
    key4: value4
---
# properties 风格
map.key1=value1
map.key2=value2
map.mapInMap.key3=value3
map.mapInMap.key4=value4
```
2. POJO
```
class POJO {
  String name;
  String desc;
}
---
# yaml
pojo:
  name: name
  desc: desc
pojoList:
  - name: aa
    desc: desca
  - name: bb
    desc: descb
---
# properties
pojo.name=name
pojo.desc=desc

pojoList[0].name=aa
pojoList[0].desc=desca
pojoList[1].name=bb
pojoList[1].desc=descb
```
### 对应关系不存在的情况
---
上面提到，KV 的表达范围要大于 YAML，以常用的日志级别配置为例，使用 properties 可以在将 package 打印级别设置为 warn 的基础上，单独将某个类的打印级别设置为 error。

但是这种配置方式不符合 YAML 格式，所以无法转换到 YAML 格式。为什么会这样呢？因为这种表达方式在 YAML 中，key `logging.level.com.example` 存在歧义，它既可能为标量，也可能为映射。
```yaml
logging.level.com.example=warn
logging.level.com.expamle.HelloController=error
---
#logging:
#  level:
#    com:
#      example: info
#        HelloController: warn
```


## @ConfigurationProperties 和 @Value 差异

在 Spring Boot 中，通过在 JavaBean 类 @ConfigurationProperties 注解或者在类字段上添加 @Value 注解或者的方式，我们可以将配置在运行时加载到目标对象。

[Spring Boot 文档] 列出了 @ConfigurationProperties 和 @Value 差异，@ConfigurationProperties 有 `Relaxed binding` 和 `Meta-data support` 特性，而 @Value 有 `SpEL evaluation` 特性。

| Feature           | @ConfigurationProperties |@Value|
| ------------------| -------------------------|------|
| Relaxed binding   | Yes                      | NO   |
| Meta-data support | Yes                      | NO   |
| SpEL evaluation   | NO                       | YES  |

`Relaxed binding` 一般是指
- 绑定 dash-separated properties 到驼峰式变量，如 local-copy 到 localCopy
- 绑定全大写到小写，如 PORT 到 port
- 复合绑定，ACME_MYPROJECT 到 acme.my-project，一般用在环境变量
- Underscore notation 下划线分隔到驼峰式，如 local_copy 到 localCopy

`Meta-data support` 指的是，如果应用项目引入 spring-boot-configuration-processor 依赖，包内的 Java 注解处理器（annotation processor）会在编译时会生成一份配置 JSON 描述文件。该文件记录了编译生成的 配置项到 JavaBean 类映射，你可以在 target/classes/META-INF 目录找到它。
```
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-configuration-processor</artifactId>
    <version>2.0.4.RELEASE</version>
    <optional>true</optional>
</dependency>
```
JSON meta 的最大作用是供 IDE 提供交互，比如在 IDEA 中，你可以直接从配置文件跳转到对应 JavaBean 类。

`SpEL 表达式` 特性则意味着应用初始化时，Spring 框架将对应配置作为 String 参数运行 `#{${...}}` 声明的表达式进行，最终运算结果会被绑定到对象字段。

下面探讨绑定差异
### 标量绑定
对 String 和 char, boolean, byte, short, int, long, float, double 及其对应包装类而言，两者没有差异。
```
value:
  maxValue: 0x7FFFFFFF # parse max value 2147483647
  nullValue: null # parse to String "", Integer null
  trueValue: true # parse to true
  trueCmp: 2==2 # parse to true
  s_byte: 9 #...
  s_char: 8 #...
  s_double: 5.3 #...
  s_float: 2.1 #...
  s_int: 5 #...
  s_long: 3 #...
  s_short: 2 #...
```

### 序列绑定
对于序列类，@ConfigurationProperties 可以绑定到 Collection, List, Set 和 Array。

在配置可用前，YAML 会被转换为 properties 风格，也就说 sequence.strs 配置其实并不存在，Environment 中可用的配置其实是 sequence.strs[0], sequence.strs[1], sequence.strs[2]。

SpEL 本质是一种针对 String 类型的运算，我们可以将配置拼接起来 (`#{'${sequence.strs[0]},${sequence.strs[1]},${sequence.strs[2]}'}`)，再使用 SpEL 解析成 Collection, List, Set，Array。

如果我们直接使用 properties 风格配置，无需使用 SpEL 即可完成转换。

```java
sequence:
  strs: ["a","b","c"]
---
properties.strs = a,b,c
---
// @ConfigurationProperties 绑定声明
@ConfigurationProperties(prefix="sequence")
@Data
public class SequenceBean {
    private List<String> strs;
    // 或者
    // private Set<String> strs；
    // 或者
    // private Collection<String> strs；
    // 或者
    // private String[] strs;
}
---
// @Value 绑定声明
@Component
public class SequenceClzz {
    @Value("#{'${sequence.strs[0]},${sequence.strs[1]},${sequence.strs[2]}'}")
    // 或者  @Value("${properties.strs}")
    private String[] strs;
    
    @Value("#{'${sequence.strs[0]},${sequence.strs[1]},${sequence.strs[2]}'}")
    // 或者  @Value("${properties.strs}")
    private List<String> strList;

    @Value("#{'${sequence.strs[0]},${sequence.strs[1]},${sequence.strs[2]}'}")
    // 或者  @Value("${properties.strs}")
    private Set<String> strSet;
    
    @Value("#{'${sequence.strs[0]},${sequence.strs[1]},${sequence.strs[2]}'}")
    // 或者  @Value("${properties.strs}")
    private Collection<String> strCollection;
}
```

### 映射绑定
对于映射类配置，@ConfigurationProperties 可以很自然绑定到 Map 对象 和 POJO 对象。

```java
mapping:
  map:
    key1: value1
    key2: value2
    mapInMap:
      key3: value3
      key4: value4
  pojo:
    name: name
    desc: desc
  pojoList:
    - name: aa
      desc: desca
    - name: bb
      desc: descb
---
@ConfigurationProperties(prefix="mapping")
@Data
public class MappingBean {
    private Map<String,Object> map;
    private POJO pojo;
    private List<POJO> pojoList;

    @Data
    public static class POJO{
        String name;
        String desc;
    }
}      
```
与序列类似，@Value 映射类配置绑定，需要将配置处理成 String 标量，只支持 Map 而不支持 POJO。
```java
mapping.map={key1:'value1',key2:'value2'}
mapping.map.mapInMap={key3:'value3',key4:'value4'}

// 无法绑定
// @Value("#{${mapping.pojo}}")
// private POJO pojo;
```

## 总结
KV 是 YAML 超集这一点很容易发现，普通开发人员直接了解并合理混合文件即可避免。但如果你需要为公司开发远程配置中心，则需要格外小心。最好不要将所有配置存储在一个大配置源中，并支持用户在 KV 编辑器和 YAML 编辑器之间切换，而是要采用类似 Spring Boot 的方式，将 YAML 和 KV 分为两个配置源，在使用时将其统一为 KV 即可。当然，你也可以与同事约定远程配置中心只支持 KV 风格而不支持 YAML 风格。

如果某个远程配置中心只支持 KV 配置（嗯，你同时真这么干了），而你又需要使用序列配置，Spring Boot 会将序列配置元素转换为 key[idx] 的小技巧可以帮助你解决一些烦恼。

进一步讨论 @Value 和 @ConfigurationProperties：
* @Value 其实只支持 String 标量，可以通过 Spring Boot 内置的转换逻辑（通常是 Converter 接口实现）或者 SpEL 转换到 Array, List, Set, Collection 和 Map，但无法注入配置到 POJO 对象。@ConfigurationProperties 对标量、序列和映射对支持都很好。
* @Value 比较适合配置较少，或者需要对配置做一定计算的场景。@ConfigurationProperties 适合配置较多，需要将配置依据业务域分割的场景。
* 大部分时候都推荐多用 @ConfigurationProperties，因为它背后是 JavaBean，配置赋值时不涉及反射，而 @Value 基本都用到了反射。

最后，@Value 解析实现在 org.springframework.beans.factory.annotation 包下的 AutowiredAnnotationBeanPostProcessor#postProcessProperties，
@ConfigurationProperties 解析实现在 org.springframework.boot.context.properties 包下ConfigurationPropertiesBindingPostProcessor#postProcessBeforeInitialization。


延伸阅读
- [YAML 官方文档](https://yaml.org/)
- [阮一峰：数据类型和 Json 格式](http://www.ruanyifeng.com/blog/2009/05/data_types_and_json.html)
- [Spring Boot 配置文档](https://docs.spring.io/spring-boot/docs/current/reference/html/spring-boot-features.html#boot-features-external-config)
- [SpEL Docs](https://docs.spring.io/spring/docs/current/spring-framework-reference/core.html#expressions)
- [baeldung: Guide to @ConfigurationProperties in Spring Boot](https://www.baeldung.com/configuration-properties-in-spring-boot)
- [baeldung: A Guide to Spring Boot Configuration Metadata](https://www.baeldung.com/spring-boot-configuration-metadata)


[Spring Boot 文档]: https://docs.spring.io/spring-boot/docs/current/reference/html/spring-boot-features.html#boot-features-external-config-vs-value