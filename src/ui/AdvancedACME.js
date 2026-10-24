// DSM desktop integration: opens the Advanced ACME web interface in a DSM window.
Ext.namespace("SYNO.SDS.AdvancedACME");

Ext.define("SYNO.SDS.AdvancedACME.Application", {
  extend: "SYNO.SDS.AppInstance",
  appWindowName: "SYNO.SDS.AdvancedACME.MainWindow",
  constructor: function () {
    this.callParent(arguments);
  }
});

Ext.define("SYNO.SDS.AdvancedACME.MainWindow", {
  extend: "SYNO.SDS.AppWindow",
  constructor: function (config) {
    this.appInstance = config.appInstance;
    // DSM sets jsConfig (from ui/config) on the prototype of every class listed
    // there; jsBaseURL is the package's UI folder, webman/3rdparty/<package
    // name>. The package name differs between builds.
    var base = (this.jsConfig && this.jsConfig.jsBaseURL) || "webman/3rdparty/AdvancedACME";
    SYNO.SDS.AdvancedACME.MainWindow.superclass.constructor.call(this, Ext.apply({
      layout: "fit",
      resizable: true,
      cls: "syno-app-win",
      maximizable: true,
      minimizable: true,
      width: 1100,
      height: 760,
      // The timestamp prevents the browser from showing a cached page after updates.
      html: '<iframe src="' + base + '/index.html?v=' + Date.now() +
        '" style="width:100%;height:100%;border:none;margin:0" title="Advanced ACME"></iframe>'
    }, config));
  },
  onClose: function () {
    SYNO.SDS.AdvancedACME.MainWindow.superclass.onClose.apply(this, arguments);
    this.doClose();
    return true;
  }
});
