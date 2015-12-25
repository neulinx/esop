# Log of development, Chinese edition.
* * *

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
