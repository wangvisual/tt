// https://erhanabay.com/2009/01/29/dynamic-grid-panel-for-ext-js/
Ext.ux.DynamicGridPanel = Ext.extend(Ext.grid.GridPanel, {
    initComponent: function(){
        /**
        * Default configuration options.
        *
        * You are free to change the values or add/remove options.
        * The important point is to define a data store with JsonReader
        * without configuration and columns with empty array. We are going
        * to setup our reader with the metaData information returned by the server.
        * See http://extjs.com/deploy/dev/docs/?class=Ext.data.JsonReader for more
        * information how to configure your JsonReader with metaData.
        *
        * A data store with remoteSort = true displays strange behaviours such as
        * not to display arrows when you sort the data and inconsistent ASC, DESC option.
        * Any suggestions are welcome
        */
        var config = {
            viewConfig: {forceFit: true},
            border: false,
            stripeRows: true,
            columns: [],
        };
        Ext.apply(this, config);
        Ext.apply(this.initialConfig, config);
        Ext.ux.DynamicGridPanel.superclass.initComponent.apply(this, arguments);
    },
    onRender: function(ct, position){
        var that = this;
        this.colModel.defaultSortable = true;
        Ext.ux.DynamicGridPanel.superclass.onRender.call(this, ct, position);
        this.el.mask('读取数据中...');
        this.store.on('metachange', function(){
            /**
            * Thats the magic!
            * JSON data returned from server has the column definitions
            */
            if(typeof(this.store.reader.jsonData.columns) === 'object') {
                var columns = [];
                /**
                * Adding RowNumberer or setting selection model as CheckboxSelectionModel
                * We need to add them before other columns to display first
                */
                if(this.rowNumberer) { columns.push(new Ext.grid.RowNumberer()); }
                if(this.checkboxSelModel) { columns.push(new Ext.grid.CheckboxSelectionModel()); }
                Ext.each(this.store.reader.jsonData.columns, function(column){
                    if ( column.renderer ) {
                        column.renderer = that.renders[column.renderer];
                    }
                    columns.push(column);
                });
                this.getColumnModel().setConfig(columns);
            }
            this.el.unmask();
        }, this);
        this.store.load();
    }
});
