需要优化执行效率，以下面的命令为测试方法。记录当前的耗时，并对比优化后的耗时，优化结果输出记录到report.md
run shell:
```
vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif
```
baseline exe placed at: D:\Apps\ffmpeg\vimg.exe


优化点：
1、减少IO读写次数，避免写入临时文件，尽量使用内存保存临时文件。
2、利用硬件加速，nvidia显卡。
