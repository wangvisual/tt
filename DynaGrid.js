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

// https://gist.github.com/onia/ce603b6e49d0883eb209
/* original author: Alexander Berg, Hungary */
Ext.grid.RadioGroupColumn = Ext.extend(Ext.grid.Column, {
    xtype: 'radiogroupcolumn',
    constructor: function(cfg){
        Ext.grid.RadioGroupColumn.superclass.constructor.call(this, cfg);
        this.renderer = function(value, metadata, record, rowIndex, colIndex, store) {
            var column = this;
            var name = "_auto_group_" + record.id;
            var html = '';
            if (column.radioValues) {
                column.radioValues.forEach( function( radioValue ) {
                    var radioDisplay;
                    if (radioValue && radioValue.fieldValue) {
                        radioDisplay = radioValue.fieldDisplay;
                        radioValue = radioValue.fieldValue;
                    } else {
                        radioDisplay = radioValue;
                    }
                    html = html + "<input type='radio' name = '" + name + "' " + (radioValue == value ? "checked='checked'" : "") + " value='" + radioValue + "'>" + radioDisplay;
                } );
            }
            return html;
        };
        this.addListener('click', function(me, g, rowIndex, e) {
            if ( e && e.target && e.target.name && e.target.name.startsWith("_auto_group_") && e.target.value ) {
                var record = g.getStore().getAt(rowIndex);
                record.set(me.id, e.target.value); // change the record, set dirty/modified flag
                if ( record.modified && record.modified[me.id] == e.target.value ) record.reject(); // reset to init
            }
        });
    },
});

Ext.grid.Column.types.radiogroupcolumn = Ext.grid.RadioGroupColumn;

