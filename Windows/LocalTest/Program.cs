using ProCam;
VideoDecoder.Initialize("/opt/homebrew/opt/ffmpeg/lib");
return SelfTest.Run(new[] { "--selftest", args.Length > 0 ? args[0] : "../testdata" });
