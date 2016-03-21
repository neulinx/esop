# 开发日志
* * *

## 20160321 分支
同一个develop项目维护多个不同发布的办法有两个，一个是采用submodule，另一个是采用branch。感觉还是采用branch更加简单一致些。

因此，把DataEngine项目通过Branch方式引入到develop项目中。

## 20160303 高铁上
 
### make & npm
由于项目混合了 Rust、JavaScript、Dockerfile、shell脚本等等涵盖编码、测试、部署各个环节，所以需要采用一个统一的构建工具。从普适性来讲，make是不错的选择。

首先是把JavaScript开发使用的npm构建工具融合到Makefile中去。npm的主要工作是把ES6转换成为JavaScript。

## 20160223 Total Platform
时代在变化，运维研发已经融合，全面采用软件开发技术实现全平台的构建，包括部署。

我个人来讲，

采用容器化平台部署的几个问题

* 采用哪种API或者管理框架。
    * 可以选择第三方构建好的完善的平台，如 Google 的 kubernetes，Docker系的docker compose / docker swarm
    * 也可以直接选择最基础的Docker Remote API，自己Groundup。

我倾向于后者，用最基础的Docker API。

* 使用etcd还是arangodb来持久化数据。

我倾向于arangodb，但是前期可以考虑混合模式。

* 使用JavaScript语言还是rust语言。

我倾向于使用混合语言。性能敏感、底层交互、模块化使用rust，框架、业务使用JavaScript。

## 20160126 具体而微
不能再搞宏大叙事了，扎扎实实按照逐步求精、快速迭代的模式进行开发。直接面向自己的平台应用，做到 “dogfooding”。让系统和框架在合适的时候涌现出来。

## 切换到具体项目，All-in-one
项目当前聚焦：新联通信平台，**Neulinx Communications Platform**
关键字：数据、流程、联系（通信）

## deploy
1. 开发环境，CoreOS Vagrant
2. 发布制品，Dockerfile

## 系统引入
1. CoreOS
2. Kamailio
3. SEMS

* * *

## 20160121
### entry
作为actor入口点，相当于factory函数，同时兼顾后续的数据结构。

## 20160120
### 合二为一
合并 sop.js与sop.rs，还是以rust为框架，以foxx为应用端。
 
### 忍是一种美德
为了让应用开发者适应，Actor或者FSM自定义逻辑必须支持Javascript语言编程。

说起一步到位，那也应该是至少精通两种语言。就当前的技术形势来看，Rust和Javascript这两种语言的组合基本可以做到全覆盖。当然也可能存在其他更好的组合，但就我个人的偏好来说，就这两种语言吧。

吐槽一下Visual Studio Code的RustCode，安装的丑陋不必说，安装好后一大堆的bug要把人搞崩溃。好吧，我先用Javascript写些“存储过程”等你好了。

## 20160119 忍无可忍，无需再忍
在 ES6 与 Javascript 中精神分裂，在 function 与 class 痛苦抉择，在为多线程模式下的协同焦虑。同时还要忍受对 rust 新语言心痒难搔的煎熬 ... ...

年纪大了，时间有限，还是一步到位吧。决定放弃 Javascript 语言开发基础框架，还是使用 rust 吧。即使以后遇到千难万险，自己约的含泪也要打完。

* * *

## 20160119 禁止防御性编程，想法都不要有
但是必须要有一层异常捕获机制，统一进行故障转移和自愈。

## 20160114 逐步求精开发模式
比如，设计state.create 函数，先确定输入和输出，然后逐步求精。

逐步求精法的要义是，快速构建一个可以调试交付的原型，以最快的速度进入演进迭代器。避免过度设计和初始偏差。

### Makefile
拥抱ES6，代价是需要一个转换器。没有做太多考虑，选择了Babel。转换过后看看代码，感觉自己是不是太激进了？其实现阶段只需要使用 arrow function。其他的当前V8引擎已经支持了。

既然做了Makefile，顺带把 foxx-manager 的几个命令也在Makefile中实现。

## 20160113 重构
完美主义者明知过早优化是万恶之源，但实在是不能忍，还是必须要满足自己的审美观。因此，现在就开始重构吧。

1. 创建一个State类，用于生成各种状态对象。
2. State类中包含 cache, meta, misc 和 method 四个基础section。其中 cache 就是这个State类的一级属性。
3. State对象实例创建后，按需获取数据、创建对象，根据情况在cache中缓存。
4. 支持缓存的清除。
5. method支持模块、类和数组三种形式。基本的划分是entry, exit, activity 和 reactions。

## 20160110 归一化考虑
当前的Platform、 System、Actor和State是各自独立的设计。从美学角度看不符合我的审美。下一个版本，平台、系统和状态机要归一化设计，统一以状态的形态呈现，采用Graph结构建立特异性及数据时间的推送传播。

## 20160109 kv store
重新进行设计，强制支持 kv store

## 20160108 存储封装
封装arangodb collection的行为。当前只支持get/set两种方法。其中set方法中隐含支持 update 和 remove。

由于arangodb是一个document数据库，对key-value数据不提供直接的访问支持。看到arangodb中对嵌套的json数据对象的处理效率还不错，对于key-value对类型的数据，统一增加key和value字段。

## 20160105 回退
### 隐变量
去除`action`和`reaction`中的`this`后，面临了一个问题。当外部使用这些API时，必须传递进去`state`变量，而这个显式的变量具有对这个`actor`的最高级别的访问权限，这就带来了安全性设计的隐患。因此，还是回到以`this`作为隐式变量的方式，来规避对数据访问权限的滥用。

### 继承
像我这样对OO有着本能反感的人，回退到使用OO最坏的部分：**继承**也是需要很大的勇气。但是当前也没办法，ES6的支持斑斑驳驳，JS千疮百孔，只能拾起继承来实现数据对象最基本的操作。为了规避继承陷阱，要把可继承的属性做到最少。当前的actor只需要继承get和set两个方法即可。

### state是可变的
原来基于 functional programming，需要在返回值中包含更改后的变量

## 20160104 剔除 `this`
去除 actions 和 reactions 函数中的 `this`

## 20160103 高铁速码

高铁是一个封闭的环境，写起代码来很高效啊。

MacOS X 系统的鼠标指针真让人抓狂，所有我喜欢的 Dark Theme 的文本光标都是黑色的，让人难以辨认。包括 Code 和 Ulyssis 。没办法，只好切换成 Solarized Light 配色方案。

## 20160101 滚回ES5
开开心心ES6，垂头丧气滚回ES5.
首先是 harmony_modules 居然当前所有版本的V8都不支持。然后是居然 arangodb 居然不支持 arrow function。最后是 Object.assign 都不支持。看看当前的arangodb development 分支，V8引擎用的居然还是 v4.3.61，连4.5都不是。当然，狠一点可以在本机使用最新的V8, 但是看看V8对ES6当前的兼容性... ... 别折腾了，还是滚回ES5吧。不过不甘心的我还是命令行启用了 arrow function。

```
echo $(arangosh --javascript.v8-options="--help" | awk '/harmony/ && $1 ~ /^--/{print $1}')

--es_staging --harmony --harmony_shipping --harmony_modules --harmony_arrays --harmony_array_includes --harmony_regexps --harmony_arrow_functions --harmony_proxies --harmony_sloppy --harmony_unicode --harmony_unicode_regexps --harmony_rest_parameters --harmony_reflect --harmony_computed_property_names --harmony_tostring --harmony_numeric_literals --harmony_classes --harmony_object_literals

```


## 20151230 system

- 分离数据与行为；分离内部与外部API。
- 把系统作为平台的一级成员。
- 把通用的函数放到 sop.js 中去。


## 20151229 result
设计一种标准的返回格式。参考 Erlang SOP 项目。`{Directive, Output, NewState}`

## 20151228 快速开发
### 编码规则补充

- 对象内部私有变量加前缀 '_' 
- 模块内部的全局变量采用**PascalCased**, 即首字母大写。
- 采用**semicolon-less**代码风格，不使用';'。

## 20151227 归一化的数据对象
### 避免过度设计
采用按需编码原则。

### key 与 options 参数项的合并
为了兼容Object的'.'运算符和'[]'运算符，get/set函数不应该有Options参数项。不过需要把Key参数的定义重新设计一下。

key参数的标准形式为对象，如`{key: theKey}`。对象中的其他属性可以等同于原来的Options参数项。除了标准的对象模式，当key为字符串时，相当于`{key: 'key'}`的简化写法。

set返回值的key则不应该是对象，而是key参数对象中的`key`属性值。

### 数据对象的method
可以参考map的method。本来认为 has 函数没必要，get返回undefined时即可判断。不过如果考虑到取值会带来效率问题，则可以勉强保留has。换一种思路，如果能够类似 HTTP 的HEAD method，也同样可以丢掉has函数，并解决取值效率问题。


## 20151226 需求驱动

### 数据对象的行为
如果当前 Javascript 引擎支持 ES6 proxy 的话，"."可以是唯一的行为。当前，则是 get 和 set 两个方法。

### get 函数参数设置
get函数的标准形式是：`get(key) => value` 当用get函数获取层级数据时，一种方法是在key参数中加入层级。key可以是数组 `[root, branch, leaf]`。另一种方法是采用ES6推荐的层级调用模式 get(root).get(branch).get(leaf). 第一种效率高些，第二种则更加javascript化。好吧，我选第二种。

为了避免出现递归循环，get层级操作时需要加入对递归次数参数。类似这样的参数还很多，因此，get函数需要加第二个参数options。从容易遍历操作的角度来看，options采用数组比较合适；从容易选择操作来讲，采用对象更方便。我还选对象形式，这样也是更加Javascript化些。此外，options也可以为基础数据类型，如字符串、数字等，当然也包括 undefined、null。

因此，get 的函数形式为： `get(key, options) => value`。 避免suprise的话，默认 `options = {}`

### set 函数
同样的，set函数形式定义为：`set(key, value, options) => key`。options中有 `create: true` 时，当key不存在时，自动创建该key；否则set函数不成功。函数调用成功的返回值为key，失败的话返回`null`。参数key为`void 0`时，表明要创建新的数据项，返回新的key值。

## 20151225 起航

### one-commit-per-day
身为码农，每日已提交是基本的纪律性。

### 建立统一的版本库
既然 git 如此给力，完全可以建立一个个人的开发库，以 master 为主分支，不同的开发项目放置到不同分支中。交付出去的分支可以通过 Pull Request 合并到其他独立项目中。这样一来可以通过跟踪一个个人版本库来检查自己是否完成了**每日提**的任务。

### 从 sop 项目开始
sop 是我念兹在兹的一个终生项目，就从它开始吧。

### 进度计划
阶段一，完成一个 Graph 数据 REST API。就是 data engine 项目，已经算是完成。
阶段二，基于 arangodb 快速构建一个 Actor Model 平台。实现对后端 PHP 开发的替代。正在进行中。
阶段三，细化 Actor Model 实现 面向状态的 FSM 平台。阶段二完成后启动。

### sop 设计

- 基于 arangodb foxx 框架
- 采用 ECMAScript 6 编程语言
- 采用 Actor Model 模式
- 包含 platform, system, actor 三个层次
- 每个 actor 包含数据和行为两部分。
- actor 数据包含 Meta data 和 Misc data 两部分，Miscellaneous data 存储在 kv 库中。
- actor 数据支持聚合，有控制访问上层数据。
- actor 行为包含 entry, exit, activity 和 reaction. 其中 reaction 是对外提供的接口。其他行为函数内部调用。
- actor 的事件及数据推送基于 actor 之间的 graph 关系，沿着特定的 edge （channel）传播。
- 当前 actor 实例由 entry 行为产生。actor 行为函数可以在文件模块中，也可以直接在数据库中，都统一采用 entry 作为 actor factory。
