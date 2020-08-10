---
title: "Java 类型擦除与泛型信息恢复"
date: 2019-06-23T08:15:19+08:00
lastmod: 2019-06-28T08:15:19+08:00
draft: false
keywords: ["java"]
description: ""
tags: ["java"]
author: "Zeng Xu"
summary: "类型擦除（Type Erasure）其实潜藏着 2 层概念：对于 JVM 而言，泛型参数被擦除了；对于 Java 语言来说，泛型信息得到了很大程度保留"

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
讨论起 Java 泛型，书籍博客经常会提到类型擦除（Type Erasure），其实潜藏着 2 层意思：
* 类型擦除其实是一个运行时概念，指的是对于 JVM 而言，泛型参数被擦除了。
* 对于 Java 语言来说，泛型信息其实得到了很大程度保留，否则便无法解决数据对象的反序列化问题

## 类型擦除（Type Erasure)
类型擦除实现意味着运行期间，JVM 并不知道类型信息，直观感受是：
* 无法使用泛型创建对象
* 无法使用泛型创建数组
* 无法针对泛型执行实例判断

```java
public class SimpleGeneric<T> {
    T t;

    SimpleGeneric(T t) {
        this.t = t;
    }

    void erased(T t) {
        // 无法使用泛型创建对象
        // T nt = new T();

        // 无法使用泛型创建数组
        // T[] arr = new T[];

        // 无法针对泛型执行实例判断
        // if(t instanceof T){
        //     ...
        // }
    }

    T getTarget() {
        return t;
    }

    public static void main(String[] args) {
        SimpleGeneric<String> strSg = new SimpleGeneric<>("hello");
        String str = strSg.getTarget();
    }
}
```
使用 `javap -v SimpleGeneric.class` 查看编译后的字节码描述符可以发现：
* 字段 t 对应 `Ljava/lang/Object;`
* 单参构造函数对应 `(Ljava/lang/Object;)V`
* 方法 getTarget 对应 `()Ljava/lang/Object;`

如果我们将类声明改为 `SimpleGeneric<T extends CharSequence>`，对应的描述符则变为如下
* 字段 t 对应 `Ljava/lang/CharSequence;`
* 单参构造函数对应 `(Ljava/lang/CharSequence;)V`
* 方法 getTarget 对应 ` ()Ljava/lang/CharSequence;`

也就是说，如果泛型参数没有 extends 限定，类型被擦除为 Object，如果有 extends 限定，类型被擦除为限定类型。如果有多个限定类型，如 `SimpleGeneric<T extends CharSequence & Comparable<? extends CharSequence>>`，则类型被擦除为最左边的限定（即 CharSequence）。

### 类型转换检查指令插入
进一步观察 main 函数 `String str = strSg.getTarget();` 字节码

```java {linenos=table,hl_lines=[3],linenostart=1}
aload_1           // 加载对象引用 strSg 到操作栈
invokevirtual #6  // 方法调用 getTarget:()Ljava/lang/Object;
checkcast     #7  // class java/lang/String，检查方法返回是否为 String 类型
astore_2          // 存储返回对象引用到局部变量表（相当于 String str = {目标值}） 
```
在涉及泛型赋值处，Java 编译器会插入 `checkcast` 指令，保证类型安全。如果指令失败（返回类型与目标类型不匹配），JVM 会抛出 ClassCastException。

这点是为保证泛型体系与非泛型体系兼容而设置，下面代码展示类型检查必要性

```
List<String> strs = new ArrayList<>();
List rawList = strs;
rawList.add(1);
String str = strs.get(0); // 这里将抛出 ClassCastException
...
```
Java 为保证泛型体系与 1.5 之前体系兼容，允许泛型 List<String> 到裸类型 List 赋值。代码接着往 List 对象加入整型 1，由于类型擦除，JVM 并不阻止这种行为。最后，代码尝试取值，由于 `checkcast` 指令作用，代码流程被终止。

这里如果不做检查而将 Integer 对象赋给 String 引用，将发生不可预期后果，所以 Java 语言选择抛出异常终止代码运行。

正如 [Java 语言规范第 8 版] 指出，编译器实施的类型擦除、类型转换检查指令插入和桥接方法生成一起构成了 Java 泛型实现
> To implement generics, the Java compiler applies type erasure to:
> 
> 1.Replace all type parameters in generic types with their bounds or Object if the type 
> parameters are unbounded. The produced bytecode, therefore, contains only ordinary classes, 
> interfaces, and methods.
>
> 2.Insert type casts if necessary to preserve type safety.
> 
> 3.Generate bridge methods to preserve polymorphism in extended generic types.

桥接方法是指针对涉及泛型类的实现或者继承情况，编译器会在子类中自动插入桥接类型方法，保证子类正常覆写父类方法，维续 Java 语言的多态特性，详细介绍见 [Oracle Java 泛型介绍#桥接方法] 和 [stackoverflow 讨论]。

## 泛型信息恢复
上文提到，类型擦除更多只是针对 JVM 而言。事实上，Java 编译器仍在 class 文件以 Signature 属性的方式保留了泛型信息。对于 JVM 而言，Signature 并不是必须属性，其作用类似标签。运行期间，Java 类库可以利用这些标签恢复泛型信息（Class 类和反射包）。

下面将以 Generic 类为例展示信息恢复：

```java
public class Generic<T extends Comparable<T>> {
    List<T> list;

    public <EX extends NullPointerException> List<? extends CharSequence> doSomething(T task) throws EX {
        return null;
    }
}
```
使用 javap 查看 Generic.class 字节码可以找到这些 Signature 
* class **Generic** signature: `<T::Ljava/lang/Comparable<TT;>;>Ljava/lang/Object;`
* method **doSomething** signature: `<EX:Ljava/lang/NullPointerException;>(TT;)Ljava/util/List<+Ljava/lang/CharSequence;>;^TEX;`
* field **list** signature: `Ljava/util/List<TT;>;`

Java 泛型系统由 5  种类型构成
* TypeVariable，对应 `<T extends Comparable<T>>` 中的 T 标识，它可以由 extends 设置 upper 限定，由 super 设置 lower 限定，这里 upper 限定为 Comparable。Java 可以在类、构造方法、普通方法三处声明 TypeVariable
* ParameterizedType，对应 `List<T>`、`List<String>` 等格式
* WildCardType，对应 `? extends CharSequence` 中的 `?`，它可以有由 extends 设置 upper 限定，由 super 设置 lower 限定，这里 upper 限定为 CharSequence
* GenericArrayType，对应 `T[]`
* Class，又称之为裸类型（RawType)，对应不带尖括号 `<>` 类，诸如 `List`, `Generic`

### 类泛型信息恢复
Class 类提供的 getTypeParameters, getGenericSuperclass 和 getGenericInterfaces 可分别用于获取类声明泛型信息、类似声明中父类泛型信息和类声明中接口泛型信息。

下面代码展示了如何获取 Generic 类声明中的 TypeVariable `T extends Comparable<T>` 信息

```java
TypeVariable clzParam = (TypeVariable)  Generic.class.getTypeParameters()[0];
System.out.println("class info : " + clzParam + ", class typeVariable bounds : " + Arrays.asList(clzParam.getBounds()));

//~
class typeVariable info : T, class typeVariable bounds : [java.lang.Comparable<T>]
```

声明 SubGeneric 类继承类 `Generic<String>` 并实现接口 `Consumer<String>`，其字节码文件保留的 class Signature 为 `Ltype/Generic<Ljava/lang/String;>;Ljava/util/function/Consumer<Ljava/lang/String;>;`。对应泛型信息可按如下方式获取

```java
class SubGeneric extends Generic<String> implements Consumer<String>{
  ...
}
---
ParameterizedType pClzParamType = (ParameterizedType) SubGeneric.class.getGenericSuperclass();
System.out.println("parent class param type info : " + pClzParamType);

ParameterizedType pInterfaceParamType =(ParameterizedType) SubGeneric.class.getGenericInterfaces()[0];
System.out.println("parent interface param type info : " + pInterfaceParamType);

//~
parent class param type info : type.Generic<java.lang.String>
parent interface param type info : java.util.function.Consumer<java.lang.String>
```
有一种常见场景是在方法中创建 TypeVariable 为某种具体类型的对象，如 `Generic<String> gs = new Generic<>()`，同时想要获取该对象的泛型信息。由于类型擦除，局部变量的泛型信息确实无从获取。针对这种场景，可以利用匿名类保留变量泛型信息（Java 编译器会为匿名类生成  class 文件）

```java
Generic<String> gs = new Generic<>(){};
Class anonymousClz = gs.getClass();
ParameterizedType varClz = (ParameterizedType) anonymousClz.getGenericSuperclass();
System.out.println("varClz class info : " + varClz);

//~
varClz class info : type.Generic<java.lang.String>
```

### 字段泛型信息恢复
Field 类提供的 getGenericType 方法可以用于获取字段泛型信息

```java
Field listField = Generic.class.getDeclaredField("list");
ParameterizedType fieldParamType = (ParameterizedType) listField.getGenericType();
System.out.println("field type info : " + fieldParamType);
TypeVariable<Class> fieldParamArg = (TypeVariable<Class>) fieldParamType.getActualTypeArguments()[0];
System.out.println("field&class typeVariable bounds : " + Arrays.asList(fieldParamArg.getBounds()));

//~
field type info : java.util.List<T>
field&class typeVariable bounds : [java.lang.Comparable<T>]
```
遇到类似上一节场景，即在方法中创建 TypeVariable 为某种具体类型的对象，同时要获取对象字段的具体类型，TypeVariable 类 getGenericDeclaration 方法可用于获取其声明处。如果应用通过匿名类的方式保留了具体类型信息，只需将匿名类中的具体类型与字段 TypeVariable 对应上即可。

### 方法泛型信息恢复
Method 类提供的 getGenericParameterTypes、getGenericExceptionTypes 和  getGenericReturnType 可分别用于获取参数、异常和返回的泛型信息

```java
Method m = Generic.class.getMethod("doSomething", Comparable.class);

TypeVariable<Method> paramType = (TypeVariable<Method>) m.getGenericParameterTypes()[0];
System.out.println("method argument info : class typeVariable " + paramType + ", bounds : "
        + Arrays.asList(paramType.getBounds()));

ParameterizedType retParamType = (ParameterizedType) m.getGenericReturnType();
WildcardType retWildcardTypeArg = (WildcardType) retParamType.getActualTypeArguments()[0];
System.out.println("method return type info : " + retParamType);
System.out.println("method return type args : " + retWildcardTypeArg);

TypeVariable<Method> exType = (TypeVariable<Method>) m.getGenericExceptionTypes()[0];
System.out.println("method exception info : method typeVariable " + exType + ", bounds : "
        + Arrays.asList(exType.getBounds()));

//~
method argument info : class typeVariable T, bounds : [java.lang.Comparable<T>]
method return type info : java.util.List<? extends java.lang.CharSequence>
method return type args : ? extends java.lang.CharSequence
method exception info : method typeVariable EX, bounds : [class java.lang.NullPointerException]
```
### 泛型信息动态生成

某些场景会涉及泛型信息的动态生成，如根据 HTTP URI 解析响应到某种泛型的特定类型，这时应用需要自行构造 ParameterizedType 实现对象。JDK 自身实现在 `sun.reflect.generics.reflectiveObjects` 包，JDK 9 后应用无法直接访问。guava 库提供了包含 ParameterizedType, WildcardType, GenericArrayType 在内的实现类，可直接利用 [Guava] 库包装类 TypeToken 动态获取实现对象

```java
 @Data
public class MessageBody<D> {
    Integer code;
    String errorMessage;
    D data;
}
---
public static <X> void dynamicGeneric(Class<X> clz) {
    TypeToken<MessageBody<X>> dynamicTypeToken =
            new TypeToken<MessageBody<X>>() {}.where(new TypeParameter<X>() {}, TypeToken.of(clz));

    Type dynamicType = dynamicTypeToken.getType();
    System.out.println(dynamicType);
    System.out.println(dynamicType instanceof ParameterizedType);
}
public static void main(String[] args) throws Exception {
  dynamicGeneric(String.class);
}
//~
type.MessageBody<java.lang.String>
true
```
下面的例子展示了 Map<K,V> 泛型信息动态生成
```java
static <K, V> TypeToken<Map<K, V>> mapOf(
        TypeToken<K> keyType, TypeToken<V> valueType) {
    return new TypeToken<Map<K, V>>() {}
            .where(new TypeParameter<K>() {}, keyType)
            .where(new TypeParameter<V>() {}, valueType);
}
---
public static void main(String[] args) {    
    ParameterizedType paramMap =
                (ParameterizedType) mapOf(TypeToken.of(String.class), TypeToken.of(Integer.class)).getType();
    
    System.out.println(paramMap);
}
//~
java.util.Map<java.lang.String, java.lang.Integer>
```

## 总结
Java 为保持对旧版本支持，1.5 以类型擦除这种比较讨巧的方式实现了泛型体系。回顾上文，我们发现它虽然带来了一些不便，但是通过一些编程技巧可以恢复出需要的泛型信息。

这种实现方式的弊端更多是性能损耗，比如字节码中频繁的 `checkcast` 指令和集合框架中处处可见的强制类型转换；再比如不支持 int, char, bool 等 primitive 类型，使得泛型的类库都只能使用包装类。

目前 OpenJDK [valhalla 项目] 正尝试采用包括引入值类型在内的多种尝试来解决 Java 泛型历史遗留问题，感兴趣可以关注。


## 延伸阅读
* [Baeldung: The Basics of Java Generics](https://www.baeldung.com/java-generics)
* [Oracle Java 泛型介绍](https://docs.oracle.com/javase/tutorial/java/generics/ww)
* [Wikipedia: Generics in Java](https://en.wikipedia.org/wiki/Generics_in_Java#Type_erasure)
* 周志明《深入理解 Java 虚拟机 （第 2 版）》，第 6 章 类文件结构，第 10 章第 3 节 Java语法糖的味道
* [The Java® Virtual Machine Specification, Java SE 8 Edition Chapter 4](https://docs.oracle.com/javase/specs/jvms/se8/html/jvms-4.html#jvms-4.1) The class File Format
* [The Java® Language Specification, Java SE 8 Edition Chapter 4](https://docs.oracle.com/javase/specs/jls/se8/html/jls-4.html) Types, Values, and Variables
* [Guava](https://github.com/google/guava)
* [valhalla 项目](https://wiki.openjdk.java.net/display/valhalla)


[Java 语言规范第 8 版]: https://docs.oracle.com/javase/specs/jls/se8/html/jls-4.html
[Oracle Java 泛型介绍#桥接方法]: https://docs.oracle.com/javase/tutorial/java/generics/bridgeMethods.html
[stackoverflow 讨论]: https://stackoverflow.com/questions/5007357/java-generics-bridge-method
[valhalla 项目]:  https://wiki.openjdk.java.net/display/valhalla
[Guava]: https://github.com/google/guava