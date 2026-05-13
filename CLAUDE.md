## 已完成：
需要优化执行效率，以下面的命令为测试方法。记录当前的耗时，并对比优化后的耗时，优化结果输出记录到report.md
run shell:
```
vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif
```
baseline exe placed at: D:\Apps\ffmpeg\vimg.exe~~


## 已优化点：
1、减少IO读写次数，避免写入临时文件，尽量使用内存保存临时文件。
2、利用硬件加速，nvidia显卡。

## 需要做的：
命令行工具以exe运行一个服务，接收yazi的dds消息，复用`ya`命令接收与发送消息。
接收的消息包括hash(file_cache)，文件路径
接收消息后运行上文的vimg vcs -c3 -H160 -n9 input_file file_cache.avif，不是以命令行的方式运行，而是直接运行
启动的服务需要实时打印更新出状态，最多同时处理10个文件。
处理完成后发送给gridthumb.yazi，gridthumb的路径在当前工程的子目录
gridthumb.yazi接收到消息后preview_widget file_cache.avif
