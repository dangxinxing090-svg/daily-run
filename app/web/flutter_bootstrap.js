{{flutter_js}}
{{flutter_build_config}}

// 预览与离线环境都从本地取 CanvasKit，不依赖 fonts/canvaskit 的 CDN。
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
  },
});
