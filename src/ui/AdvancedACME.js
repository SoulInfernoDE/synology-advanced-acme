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
    SYNO.SDS.AdvancedACME.MainWindow.superclass.constructor.call(this, Ext.apply({
      layout: "fit",
      resizable: true,
      cls: "syno-app-win",
      maximizable: true,
      minimizable: true,
      width: 1100,
      height: 760,
      // The timestamp prevents the browser from showing a cached page after updates.
      html: '<iframe src="webman/3rdparty/AdvancedACME/index.html?v=' + Date.now() +
        '" style="width:100%;height:100%;border:none;margin:0" title="Advanced ACME"></iframe>'
    }, config));
  },
  onClose: function () {
    SYNO.SDS.AdvancedACME.MainWindow.superclass.onClose.apply(this, arguments);
    this.doClose();
    return true;
  }
});
