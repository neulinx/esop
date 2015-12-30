# 开发日志
* * *

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
