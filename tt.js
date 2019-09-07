Ext.namespace('TT');

TT.app = function() {

    // private variables
    // const
    var perPage = 40;
    var tturl = './';
    var loginTypes = [ [0, '管理员'], [1, '一般用户'], [2, '无效用户'] ];
    var stageTypes = [ [0, '报名'], [1, '循环赛'], [2, '淘汰赛'], [100, '结束'] ];
    var genderTypes = [ ['未知', '未知'], ['男', '男'], ['女', '女'] ];

    var userid = '';
    var ulds; // UserList Data Store
    var shopds; // Shop Data Store
    var spinner;
    var logpanel;
    var listpanel;
    var msgpanel;

    Ext.QuickTips.init();
    Ext.form.Field.prototype.msgTarget = 'side';

    // classes
    // copy from debug.js
    var LogPanel = Ext.extend(Ext.Panel, {
        autoScroll: true,
        border: false,
        limit: 10,

        log : function(){
            var markup = [  '<div style="padding:1px !important;border-bottom:1px solid #ccc;">',
                        Ext.util.Format.htmlEncode(Array.prototype.join.call(arguments, ', ')).replace(/\n/g, '<br />').replace(/\s/g, '&#160;'),
                        '</div>'].join('');
            var addedEl = this.body.insertHtml('beforeend', markup, true);
            if ( ! this.body.addedArray ) {
                this.body.addedArray = new Array();
            }
            this.body.addedArray.push(addedEl);
            if ( this.body.addedArray.length > this.limit ) {
                addedEl = this.body.addedArray.pop();
                addedEl.remove();
            }
            this.body.scrollTo('top', 100000, true);
        },

        clear : function(){
            this.body.update('');
            this.body.dom.scrollTop = 0;
        }
    });

    var MsgPanel = Ext.extend(Ext.Panel, {

        msg : function(i,l){
            if (typeof(i)!='undefined'){
                this.body.update(i);
            }
        },

        clear : function(){
            this.body.update('');
        }
    });

    function ff(i, n) {
        if ( typeof(i) == 'string' && '' === i ) {
            return i;
        }
        if ( typeof(n) != 'number' ) {
            n = 2;
        }
        var m = 1;
        for ( var j=1; j<=n; j++ ) {
            m = m*10.0;
        }
        var r = Math.round(i*m)/m;
        return r;
    };

    function formIsDirty(panelid) {
        var pa = Ext.getCmp(panelid);
        var dirty = false;
        function isd(e) {
            if (e.items) {
                if ( e.xtype != 'fieldset' || ! e.collapsed ) {
                    e.items.each(isd);
                }
            } else if ( e.isDirty ) {
                dirty = dirty || e.isDirty();
            }
        }
        isd(pa);
        return dirty;
    }

    var editUserInfo = function(userid) {

        function editUserChanged(panel, valid){
            var u = Ext.getCmp('edituserid');
            var s = Ext.getCmp('editusersubmit');
            if ( u.originalValue == '' ) {
                u.setReadOnly(false);
            } else {
                u.setReadOnly(true);
            }
            if ( valid && formIsDirty('edituserpanel') ) {
                s.enable();
            } else {
                s.disable();
            }
        }

        function reloadUserPanel(p){
            if (typeof(userid) != 'undefined' && userid != '') {
                p.form.load({params: {action: 'getUserInfo', userid: userid}, waitMsg: 'Loading...' });
            }
        }

        var fp = new Ext.FormPanel({
            url: tturl,
            method: 'POST',
            id: 'edituserpanel',
            trackResetOnLoad: true,
            frame: true,
            reader: new Ext.data.JsonReader({
                    successProperty: 'success',
                    root : 'user'
                },[
                {name: 'userid', type: 'string'},
                {name: 'nick_name', type: 'string'},
                {name: 'cn_name', type: 'string'},
                {name: 'logintype', type: 'int'},
                {name: 'gender', type: 'string'},
                {name: 'point', type: 'int'}
            ]),
            labelWidth: 70,
            labelAlign: 'right',
            defaultType: 'textfield',
            items: [
                { fieldLabel: 'account', name: 'userid', id: 'edituserid', allowBlank: false, readOnly: true },
                { fieldLabel: '姓名', name: 'cn_name', allowBlank: true },
                { fieldLabel: '外号', name: 'nick_name', allowBlank: true },
                { fieldLabel: '类型', xtype: 'combo', name: 'logintypefake', allowBlank: false, editable: false, typeAhead: false,
                  triggerAction: 'all', lazyInit: true, lazyRender: false, mode: 'local',
                  store: new Ext.data.SimpleStore({
                         fields:['id', 'type']
                        ,data:loginTypes}),
                  displayField: 'type', valueField: 'id', hiddenName: 'logintype'
                },
                { fieldLabel: '性别', xtype: 'combo', id: 'editgendercombo', name: 'enditgenderfake', allowBlank: false, editable: false, typeAhead: false,
                  triggerAction: 'all', lazyInit: true, lazyRender: false, mode: 'local',
                  store: new Ext.data.SimpleStore({
                         fields:['id', 'type']
                        ,data:genderTypes}),
                  displayField: 'type', valueField: 'id', hiddenName: 'gender'
                },
                { fieldLabel: '积分', xtype : "numberfield", name: 'point', id: 'editpoint', allowBlank: true }
            ],
            monitorValid: true,
            listeners: {
                clientvalidation: editUserChanged
            },
            buttonAlign: 'right',
            buttons: [{
                text: 'Save', xtype: 'button', id: 'editusersubmit', type: 'submit', disabled: true,
                handler: function(){
                    fp.getForm().submit({
                        params: {action: 'editUser'},
                        success: function(){msgpanel.msg("User infomation Saved.",0); showGeneralInfo(); showPointList(); win.close();},
                        failure: function(conn,resp){
                            var msg = "Save failed";
                            if ( resp && resp.result && resp.result.msg) {
                                msg += ": " + resp.result.msg;
                            }
                            msgpanel.msg(msg,2);
                        }
                    });
                }
            },{
                text: 'Reset', xtype: 'button', type: 'reset',
                handler: function(){fp.getForm().reset();}
            }]
        });

        var win = new Ext.Window({
            title: '编辑人员',
            width:300,
            modal: true,
            items: [fp]
        });

        win.show();
        reloadUserPanel(fp);
        win.doLayout();
    };

    var editSeries = function(siries_id) {

        function editStageChange(panel, valid){
            var u = Ext.getCmp('editsiriesid');
            var s = Ext.getCmp('editseriesubmit');
            if ( u.originalValue == '' ) {
                u.setDisabled(false);
            }
            if ( valid && formIsDirty('editsiriespanel') ) {
                s.enable();
            } else {
                s.disable();
            }
        }

        function reloadUserPanel(p){
            if (typeof(siries_id) != 'undefined' && siries_id != '') {
                p.form.load({params: {action: 'getSeries', siries_id: siries_id}, waitMsg: 'Loading...' });
            }
        }

        var fp = new Ext.FormPanel({
            url: tturl,
            method: 'POST',
            id: 'editsiriespanel',
            trackResetOnLoad: true,
            frame: true,
            reader: new Ext.data.JsonReader({
                    successProperty: 'success',
                    root : 'series'
                },[
                {name: 'siries_id', type: 'int'},
                {name: 'siries_name', type: 'string'},
                {name: 'number_of_groups', type: 'int'},
                {name: 'group_outlets', type: 'int'},
                {name: 'top_n', type: 'int'},
                {name: 'stage', type: 'int'}
            ]),
            labelWidth: 70,
            labelAlign: 'right',
            defaultType: 'textfield',
            items: [
                { fieldLabel: 'ID', xtype: 'hidden', name: 'siries_id', id: 'editsiriesid', allowBlank: false, readOnly: true },
                { fieldLabel: '系列赛名字', width: 450, name: 'siries_name', allowBlank: false },
                { fieldLabel: '小组数', name: 'number_of_groups', value: 1, allowBlank: true },
                { fieldLabel: '小组出线', name: 'group_outlets', value: 1, allowBlank: true },
                { fieldLabel: '决出几名', name: 'top_n', value: 1, allowBlank: true },
                { fieldLabel: '阶段', xtype: 'combo', id: 'editstagecombo', name: 'stagefake', allowBlank: false, editable: false, typeAhead: false,
                  triggerAction: 'all', lazyInit: true, lazyRender: false, mode: 'local',
                  store: new Ext.data.SimpleStore({
                         fields:['id', 'type']
                        ,data:stageTypes}),
                  displayField: 'type', valueField: 'id', hiddenName: 'stage', value: 0,
                },
            ],
            monitorValid: true,
            listeners: {
                clientvalidation: editStageChange
            },
            buttonAlign: 'right',
            buttons: [{
                text: 'Save', xtype: 'button', id: 'editseriesubmit', type: 'submit', disabled: true,
                handler: function(){
                    fp.getForm().submit({
                        params: {action: 'editSeries'},
                        success: function(){msgpanel.msg("Series infomation Saved.",0); showSeries(); win.close();},
                        failure: function(conn,resp){
                            var msg = "Save failed";
                            if ( resp && resp.result && resp.result.msg) {
                                msg += ": " + resp.result.msg;
                            }
                            msgpanel.msg(msg,2);
                        }
                    });
                }
            },{
                text: 'Reset', xtype: 'button', type: 'reset',
                handler: function(){fp.getForm().reset();}
            }]
        });

        var win = new Ext.Window({
            title: '编辑系列赛',
            width:500,
            modal: true,
            items: [fp]
        });

        win.show();
        reloadUserPanel(fp);
        win.doLayout();
    };

    var showGeneralInfo = function() {
        function changeTxt(n) {
            if ( typeof(n) == "string" ) {
                Ext.get('infoname').dom.innerHTML = n;
                Ext.get('infoemail').dom.innerHTML = '';
                Ext.get('infogender').dom.innerHTML = '';
                Ext.get('infopoint').dom.innerHTML = '';
            } else {
                Ext.get('infoname').dom.innerHTML = "Welcome " + n.name;
                Ext.get('infoemail').dom.innerHTML = n.email;
                Ext.get('infogender').dom.innerHTML = "性别: " + n.gender;
                Ext.get('infopoint').dom.innerHTML = "积分: " + n.point;
            }
        }
        changeTxt('Loading...');
        Ext.Ajax.request({
           url: tturl,
           method: 'POST',
           success: function ( result, request) {
                    var jsonData = Ext.util.JSON.decode(result.responseText);
                    userid = jsonData.user[0].userid;
                    changeTxt(jsonData.user[0]);
                },
           failure: function () { changeTxt("Failed"); },
           params: { action: 'getGeneralInfo' }
        });
    };

    var editMatch = function(in_match_id) {
        var seriesTypes = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getSeries', filter: 'ongoing'},
            autoLoad: true,
            root: 'series',
            fields: ['siries_id', 'siries_name']
        });

        var userList = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getUserList', filter: 'valid'},
            autoLoad: true,
            root: 'users',
            fields: ['userid', 'full_name']
        });

        function editMatchChanged(panel, valid){
            var s = Ext.getCmp('editmatchsubmit');
            if ( valid && formIsDirty('editmatchpanel') ) {
                s.enable();
            } else {
                s.disable();
            }
        }

        function reloadMatchPanel(p){
            p.form.load({params: {action: 'editMatch', match_id: in_match_id}, waitMsg: 'Loading...' });
        }

        function generateGames() {
            var games = new Array();
            for ( var j=1; j<=7; j++ ) {
                var item1 = {xtype : "numberfield", fieldLabel: '第' + j +'局', name: 'game' + j + '_point1' };
                var item2 = {xtype : "numberfield", fieldLabel: ' ', name: 'game' + j + '_point2' };
                games.push({ layout : "column", xtype: 'container', defaults: {layout: 'form'}, items: [ {items: [item1]}, {items: [item2]} ] });
            }
            return games;
        }

        var fp = new Ext.FormPanel({
            url: tturl,
            method: 'POST',
            id: 'editmatchpanel',
            trackResetOnLoad: true,
            layout : "form",
            frame: true,
            reader: new Ext.data.JsonReader({
                    successProperty: 'success',
                    root : 'match'
                },[
                {name: 'match_id', type: 'int'},
                {name: 'siries_id', type: 'int'},
                {name: 'date', type: 'date'},
                {name: 'comment', type: 'string'},
                {name: 'userid1', type: 'string'},
                {name: 'userid2', type: 'string'},
                {name: 'game_win', type: 'int'},
                {name: 'game_lose', type: 'int'},
                {name: 'game1_point1', type: 'int'},
                {name: 'game2_point1', type: 'int'},
                {name: 'game3_point1', type: 'int'},
                {name: 'game4_point1', type: 'int'},
                {name: 'game5_point1', type: 'int'},
                {name: 'game6_point1', type: 'int'},
                {name: 'game7_point1', type: 'int'},
                {name: 'game1_point2', type: 'int'},
                {name: 'game2_point2', type: 'int'},
                {name: 'game3_point2', type: 'int'},
                {name: 'game4_point2', type: 'int'},
                {name: 'game5_point2', type: 'int'},
                {name: 'game6_point2', type: 'int'},
                {name: 'game7_point2', type: 'int'}
            ]),
            labelWidth: 70,
            labelAlign: 'right',
            defaultType: 'textfield',
            items: [
                { fieldLabel: '赛事', xtype: 'combo', id: 'editsetcombo', name: 'siries_id_fake', allowBlank: false, editable: false, forceSelection: true,
                  triggerAction: 'all', mode: 'local', width: 500,
                  store: seriesTypes,
                  displayField: 'siries_name', valueField: 'siries_id', hiddenName: 'siries_id'
                },
                { fieldLabel: '比赛日期', xtype: 'datefield', format: 'Y-m-d', name: 'date', allowBlank: false },
                { layout : "column", xtype: 'container', defaults: {layout: 'form'}, items: [
                    { fieldLabel: '', xtype: 'combo', id: 'edituser1combo', name: 'user1_fake', allowBlank: false, editable: false, forceSelection: true,
                      triggerAction: 'all', mode: 'local',
                      store: userList,
                      displayField: 'full_name', valueField: 'userid', hiddenName: 'userid1'
                    },
                    { xtype: 'box', autoEl: {tag: 'img', width: 48, height: 32, src: 'etc/versus.png'} },
                    { fieldLabel: '', xtype: 'combo', id: 'edituser2combo', name: 'user2_fake', allowBlank: false, editable: false, forceSelection: true,
                      triggerAction: 'all', mode: 'local',
                      store: userList,
                      displayField: 'full_name', valueField: 'userid', hiddenName: 'userid2'
                    },
                ]},
                generateGames(),
                { fieldLabel: 'comment', name: 'comment', allowBlank: true }
            ],
            monitorValid: true,
            listeners: {
                clientvalidation: editMatchChanged
            },
            buttonAlign: 'right',
            buttons: [{
                text: 'Save', xtype: 'button', id: 'editmatchsubmit', type: 'submit', disabled: true,
                handler: function(){
                    fp.getForm().submit({
                        params: {action: 'saveMatch'},
                        success: function(){msgpanel.msg("Match Saved.",0); showPointList(); win.close();},
                        failure: function(conn,resp){
                            var msg = "Save failed";
                            if ( resp && resp.result && resp.result.msg) {
                                msg += ": " + resp.result.msg;
                            }
                            msgpanel.msg(msg,2);
                        }
                    });
                }
            },{
                text: 'Reset', xtype: 'button', type: 'reset',
                handler: function(){fp.getForm().reset();}
            }]
        });

        var win = new Ext.Window({
            title: '比赛结果',
            width:600,
            modal: true,
            items: [fp]
        });

        win.show();
        reloadMatchPanel(fp);
        win.doLayout();
    };

    var showPointList = function(siries_id, siries_name, stage) {
        var myRecordObj = Ext.data.Record.create([
            {name: 'userid'},
            {name: 'employeeNumber', type: 'int'},
            {name: 'name'},
            {name: 'nick_name'},
            {name: 'cn_name'},
            {name: 'gender'},
            {name: 'win', type: 'int'},
            {name: 'lose', type: 'int'},
            {name: 'siries', type: 'int'},
            {name: 'point', type: 'int', sortDir: 'DESC'}
        ]);
        var myReader = new Ext.data.JsonReader({
            root:'users',
            id: 'userid'
        }, myRecordObj );
        var grid;
        var myds = new Ext.data.Store({
            proxy: new Ext.data.HttpProxy({
                        url: tturl,
                        method: 'POST'
            }),
            baseParams: {action: 'getPointList', siries_id: siries_id},
            autoLoad: true,
            reader: myReader,
            listeners : {
                'load': function(store, records) {
                    var selected_records = records.filter(record => record.data.siries > 0);
                    grid.getSelectionModel().selectRecords(selected_records, false);
                },
            },
            sortInfo: {field: 'point', direction: 'DESC'}
        });
        //FIXME
        var sm = new Ext.grid.CheckboxSelectionModel({
            listeners : {
                'selectionchange': function(s) {
                    s.getSelections();
                },
            },
        });
        var mycm = new Ext.grid.ColumnModel([
            //sm,
            new Ext.grid.RowNumberer(),
            {header: 'ID', width: 0, dataIndex: 'userid', hidden: true},
            {header: 'employeeNumber', width: 0, dataIndex: 'employeeNumber', hidden: true},
            {header: 'Name', width: 120, sortable: true, dataIndex: 'name'},
            {header: '姓名', width: 100, sortable: true, dataIndex: 'cn_name'},
            {header: '外号', width: 120, sortable: true, dataIndex: 'nick_name'},
            {header: '性别', width: 100, sortable: true, dataIndex: 'gender'},
            {header: '胜', width: 70, sortable: true, dataIndex: 'win'},
            {header: '负', width: 70, sortable: true, dataIndex: 'lose'},
            {header: '分数', width: 70, sortable: true, dataIndex: 'point'}
        ]);

        grid = new Ext.grid.GridPanel({
            ds: myds,
            cm: mycm,
            viewConfig: {
                forceFit: true
            },
            title : '积分概览',
            id: 'pointlist',
            autoHeight: true, // or there will be one row less
            listeners: {
                'rowdblclick': function(g, rowIndex, e) {
                    var record = g.getStore().getAt(rowIndex);
                    var data = record.get('userid');
                    editUserInfo(data);
                },
            },
            border: false,
            frame: true
        });

        if ( siries_id ) {
            var fp = new Ext.FormPanel({
                url: tturl,
                method: 'POST',
                id: 'add_user_to_siries_panel',
                trackResetOnLoad: true,
                frame: true,
                labelWidth: 70,
                labelAlign: 'right',
                items: [
                    grid,
                ],
                monitorValid: true,
                buttonAlign: 'right',
                buttons: [{
                    text: 'Save', xtype: 'button', id: 'editseriesubmit', type: 'submit', disabled: false,
                    handler: function(){
                        fp.getForm().submit({
                            params: {action: 'editSeriesUser', siries_id: siries_id, stage: stage, users: grid.getSelectionModel().getSelections().map( x => x.data.userid )},
                            success: function(){msgpanel.msg("Series infomation Saved.",0); win.close();},
                            failure: function(conn,resp){
                                var msg = "Save failed";
                                if ( resp && resp.result && resp.result.msg) {
                                    msg += ": " + resp.result.msg;
                                }
                                msgpanel.msg(msg,2);
                            }
                        });
                    }
                },{
                    text: 'Reset', xtype: 'button', type: 'reset',
                    handler: function(){fp.getForm().reset();}
                }]
            });

            var win = new Ext.Window({
                title: "报名比赛 " + siries_name + ' 按住Ctrl键或Shift键多选',
                width: 800,
                modal: true,
                items: [fp]
            });

            win.show();
            win.doLayout();
        } else {
            listpanel.removeAll(true);
            listpanel.add(grid);
            listpanel.doLayout();
        }
    };

    var showSeries = function() {
        var myRecordObj = Ext.data.Record.create([
            {name: 'siries_id', type: 'int', sortDir: 'ASC'},
            {name: 'siries_name'},
            {name: 'number_of_groups', type: 'int'},
            {name: 'group_outlets', type: 'int'},
            {name: 'top_n', type: 'int'},
            {name: 'stage', type: 'int'},
            {name: 'enroll', type: 'int'},
        ]);
        var myReader = new Ext.data.JsonReader({
            root:'series',
            id: 'siries_id'
        }, myRecordObj );
        var myds = new Ext.data.Store({
            proxy: new Ext.data.HttpProxy({
                        url: tturl,
                        method: 'POST'
                   }),
            baseParams: {action: 'getSeries'},
            autoLoad: true,
            reader: myReader,
            sortInfo: {field: 'siries_id', direction: 'ASC'}
        });
        var mycm = new Ext.grid.ColumnModel([
            {header: 'ID', sortable: true, dataIndex: 'siries_id'},
            {header: '名字', width: 600, sortable: true, dataIndex: 'siries_name'},
            {header: '小组数', sortable: true, dataIndex: 'number_of_groups'},
            {header: '出线人数', sortable: true, dataIndex: 'group_outlets'},
            {header: '取前几名', sortable: true, dataIndex: 'top_n'},
            {header: '阶段', width: 100, sortable: true, dataIndex: 'stage',
                renderer: function(value) {
                    var found = stageTypes.find(function(element) {return element[0] == value;});
                    return found ? found[1] : value;
                }
            },
            {header: '报名人数', sortable: true, dataIndex: 'enroll'},
            {xtype: 'actioncolumn', header: '报名', items: [{icon   : 'etc/enroll.png', tooltip: '编辑系列赛参与人员', handler: function(g, rowIndex) {
                var record = g.getStore().getAt(rowIndex);
                var siries_id = record.get('siries_id');
                var siries_name = record.get('siries_name');
                var stage = record.get('stage');
                showPointList(siries_id, siries_name, stage);
            }}]},
        ]);

        var toolbar = new Ext.Toolbar({
            items:[
                {
                    text:"新系列赛",
                    handler: function(){ editSeries(); }
                },
                '-',
                {
                    text:"删除系列赛",
                    handler: function(){ Ext.Msg.alert('错误', '没有实现这个功能'); }
                },
                '-',
            ]
        });
        var grid = new Ext.grid.GridPanel({
            ds: myds,
            cm: mycm,
            viewConfig: {
                forceFit: true
            },
            title : '系列赛',
            id: 'sirieslist',
            autoHeight: true, // or there will be one row less
            tbar: toolbar,
            listeners: {
                'rowdblclick': function(g, rowIndex, e) {
                    var record = g.getStore().getAt(rowIndex);
                    var data = record.get('siries_id');
                    editSeries(data);
                },
            },
            border: false,
            frame: true
        });

        listpanel.removeAll(true);
        listpanel.add(grid);
        listpanel.doLayout();
    };

    // public space
    return {
        // public properties

        // public methods
        logAjaxStart: function(conn, options) {
            spinner.setPosition(0,0);
            spinner.show();
            if ( typeof(spinner.count) == 'undefined' ) {
                spinner.count = 0;
            }
            spinner.count = spinner.count + 1;
            var p = options.params;
            if ( typeof(p) == 'string' ) {
                logpanel.log('Request: ' + p);
            } else if ( typeof(p) == 'object' ) {
                if ( p.action ) {
                    var a = p.action;
                    var s = 'Request: ' + a;
                    for(var key in p){
                        var t = typeof p[key];
                        if( t != "function" && ( t != "object" || typeof(p[key][0])!='undefined' ) && key != 'action' ){
                            s = s + String.format(" {0}={1}", key, p[key]);
                        }
                    }
                    logpanel.log(s);
                }
            }
        },

        logAjaxComplete: function(conn, response, options) {
            spinner.count = spinner.count - 1;
            if ( spinner.count <= 0 ) {
                spinner.hide();
            }
        },

        logAjaxException: function(conn, response, options) {
            spinner.count = spinner.count - 1;
            if ( spinner.count <= 0 ) {
                spinner.hide();
            }
            var r = "Exception";
            if ( response && response.statusText ) {
                r = r + ": " + response.statusText;
            }
            logpanel.log(r);
        },

        main_page: function(){

            spinner = new Ext.Panel({
                id: 'spinner',
                split: false,
                border: false,
                floating: true,
                shadow: false,
                width: 32+2,
                height: 32+2,
                html: '<img src="' + extjs_root + '/resources/images/default/shared/large-loading.gif" />'
            });

            var infopanel = new Ext.Panel({
                id: 'infopanel',
                title: '<center>' + title + '</center>',
                region: 'north',
                split: false,
                border: false,
                collapsible: true,
                height: 50,
                html: '<form name=loginform action="' + tturl + '" method="POST">'
                    + '<table id="infotable"><tr>'
                    + '<td id="infoname">Loading...</td>'
                    + '<td id="infoemail"></td>'
                    + '<td id="infogender"></td>'
                    + '<td id="infopoint"></td>'
                    + '</tr></table></form>'
            });

            var funcpanel = new Ext.Panel({
                id: 'funcpanel',
                defaultType: 'button',
                title: '功能',
                region: 'west',
                split: true,
                border: true,
                collapsible: true,
                width: 100,
                minSize: 100,
                maxSize: 200,
                defaults: { minWidth: 98, bodyStyle: 'padding: 15px' },
                items: [{
                    text: '我的信息',
                    handler: function () { editUserInfo(userid); }
                },{
                    text: '记录比赛结果',
                    handler: function () { editMatch(); }
                },{
                    text: '积分概览',
                    handler: showPointList
                },{
                    text: '增加人员',
                    handler: function () { editUserInfo(); }
                },{
                    text: '系列赛',
                    handler: showSeries
                },{
                    text: '链接'
                    // https://www.ratingscentral.com
                }]
            });

            logpanel = new LogPanel({
                id: 'logpanel',
                limit: 1000,
                layout: 'fit',
                title: 'Debug Log',
                region: 'east',
                split: true,
                border: true,
                collapsible: true,
                //collapsed: true,
                width: 120,
                minSize: 120,
                maxSize: 400,
                tbar: [{
                    text: 'Clean',
                    minWidth: 115,
                    handler: function() { logpanel.clear(); }
                }]
            });

            listpanel = new Ext.Panel({
                id: 'listpanel',
                region: 'center',
                split: true,
                border: true
            });

            msgpanel = new MsgPanel({
                id: 'msgpanel',
                region: 'south',
                height: 20,
                split: false,
                border: true
            });

            var viewport = new Ext.Viewport({
                layout:'border',
                items:[ spinner, infopanel, logpanel, funcpanel, listpanel, msgpanel ]
            });

            Ext.Ajax.on('beforerequest', TT.app.logAjaxStart, this);
            Ext.Ajax.on('requestcomplete', TT.app.logAjaxComplete, this);
            Ext.Ajax.on('requestexception', TT.app.logAjaxException, this);

            infopanel.body.on({
                'dblclick': function() { showGeneralInfo(); },
                 scope: this
            });

            logpanel.log("OK.");
            msgpanel.msg("Ready.");
            showGeneralInfo();
            showPointList();
        }
    };
}();

Ext.apply(TT.app, {
    // change public variable here if needed.
});
