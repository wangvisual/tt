Ext.namespace('TT');

TT.app = function() {

    // private variables
    // const
    var perPage = 40;
    var tturl = './';
    var loginTypes = [ [0, '管理员'], [1, '普通用户'], [2, '停用用户'] ];
    var stageTypes = [ [0, '报名'], [1, '循环赛'], [2, '淘汰赛'], [3, '自由赛'], [100, '结束'] ];
    var genderTypes = [ ['未知', '未知'], ['男', '男'], ['女', '女'] ];
    var grid_default = {
        stripeRows: true,
        border: false,
        frame: true,
        autoHeight: true,
        viewConfig: {
            forceFit: true
        },
    };

    var currentUserID = '';
    var logintype = 0;
    var ulds; // UserList Data Store
    var shopds; // Shop Data Store
    var spinner;
    var logpanel;
    var listpanel;
    var msgpanel;

    Ext.QuickTips.init();
    Ext.form.Field.prototype.msgTarget = 'side';

    var getClass = function(record) {
        if ( record.get('logintype') == 2 ) return 'Disable';
        var point = record.get('point');
        if ( point >= 1700 ) return 'Platinum';
        if ( point >= 1600 ) return 'Gold';
        if ( point >= 1500 ) return 'Silver';
        return 'Bronze';
    };

    var renderStage = function(value) {
        var found = stageTypes.find(function(element) {return element[0] == value;});
        return found ? found[1] : value;
    };

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

    function results(form, action) {
        var success = action && action.result && action.result.success ? 1 : 0;
        var msg = "保存" + (success ? '成功' : '失败');
        if ( action && action.result && action.result.msg) {
            msg += ": " + action.result.msg;
        }
        msgpanel.msg(msg, success);
    }

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
    }

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

    function getAvatar(data, use_template=true) {
        if ( !avatar_template || !use_template ) {
            return 'etc/' + data.gender + '.png';
        }
        return sprintf(avatar_template, data);
    }

    var userRecord = Ext.data.Record.create([
        {name: 'userid'},
        {name: 'employeeNumber', type: 'int'},
        {name: 'name'},
        {name: 'nick_name'},
        {name: 'cn_name'},
        {name: 'full_name'},
        {name: 'gender'},
        {name: 'email'},
        {name: 'logintype', type: 'int'},
        {name: 'win', type: 'int'},
        {name: 'lose', type: 'int'},
        {name: 'game_win', type: 'int'},
        {name: 'game_lose', type: 'int'},
        {name: 'siries', type: 'int'},
        {name: 'point', type: 'int', sortDir: 'DESC'},
        {name: 'group', type: 'int'},
    ]);

    var editUserInfo = function(editUserID) {

        function editUserChanged(panel, valid){
            var u = Ext.getCmp('edituserid');
            var p = Ext.getCmp('editpoint');
            var s = Ext.getCmp('editusersubmit');
            u.setReadOnly(u.originalValue != '');
            p.setReadOnly(logintype != 0);
            if ( valid && formIsDirty('edituserpanel') ) {
                s.enable();
            } else {
                s.disable();
            }
        }

        function reloadUserPanel(p){
            if (typeof(editUserID) != 'undefined' && editUserID != '') {
                p.form.load({params: {action: 'getUserInfo', userid: editUserID}, waitMsg: 'Loading...' });
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
            }, userRecord),
            labelWidth: 70,
            labelAlign: 'right',
            defaultType: 'textfield',
            items: [
                { fieldLabel: 'ID', name: 'userid', id: 'edituserid', allowBlank: false, readOnly: true },
                { fieldLabel: '姓名', name: 'cn_name', allowBlank: true },
                { fieldLabel: '外号', name: 'nick_name', allowBlank: true },
                { fieldLabel: '类型', xtype: 'combo', name: 'logintypefake', allowBlank: false, editable: false, typeAhead: false,
                  // https://stackoverflow.com/questions/986345/what-does-extjs-combobox-triggeraction-all-really-do
                  // After choosing an item, the list is filtered to match the current text value.
                  // triggerAction:'all' means do not filter, always show all values.
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
                        success: function(...args) {results(...args); showGeneralInfo(); showPointList(); win.close();},
                        failure: results,
                    });
                }
            },{
                text: 'Reset', xtype: 'button', type: 'reset',
                handler: function(){fp.getForm().reset();}
            }]
        });
        if ( logintype != 0 && ( typeof(editUserID) == 'undefined' || editUserID != currentUserID ) ) fp.setDisabled(true);

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

    // check if all users are still active/inactive and update the user list
    var checkAllUsers = function() {
        Ext.Ajax.request({
            url: tturl,
            method: 'POST',
            success: function ( result, request) {
                var jsonData = Ext.util.JSON.decode(result.responseText);
                results(0, {result: jsonData});
                if ( jsonData.success ) {
                    showUsers();
                }
            },
            failure: function () { results(0, {result: {success: 0, msg: ''}}); },
            params: { action: 'checkAllUsers' }
        });
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

        var items = [
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
            { fieldLabel: '外部链接', width: 450, xtype: 'textarea', name: 'links', allowBlank: true },
        ];
        stageTypes.forEach( function(element) {
            if ( element[0] != 100 ) {
                items.push(
                    {fieldLabel: element[1] + '开始', xtype: 'datefield', format: 'Y-m-d', name: 'start_' + element[0], allowBlank: true  },
                    {fieldLabel: element[1] + '结束', xtype: 'datefield', format: 'Y-m-d', name: 'end_' + element[0], allowBlank: true  });
            } else {
                items.push( {fieldLabel: '比赛结束', xtype: 'datefield', format: 'Y-m-d', name: 'start_' + element[0], allowBlank: true  });
            }
        });

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
                {name: 'links', type: 'string'},
                {name: 'number_of_groups', type: 'int'},
                {name: 'group_outlets', type: 'int'},
                {name: 'top_n', type: 'int'},
                {name: 'stage', type: 'int'},
                {name: 'start_0', type: 'date'},
                {name: 'end_0', type: 'date'},
                {name: 'start_1', type: 'date'},
                {name: 'end_1', type: 'date'},
                {name: 'start_2', type: 'date'},
                {name: 'end_2', type: 'date'},
                {name: 'start_3', type: 'date'},
                {name: 'end_3', type: 'date'},
                {name: 'start_100', type: 'date'},
            ]),
            labelWidth: 70,
            labelAlign: 'right',
            defaultType: 'textfield',
            items: items,
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
                        success: function(...args) {results(...args); showSeries(); win.close();},
                        failure: results,
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
                Ext.get('infoname').dom.innerHTML = "欢迎" + loginTypes[n.logintype][1] + " " + n.name;
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
                    currentUserID = jsonData.user[0].userid;
                    logintype = jsonData.user[0].logintype;
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
            autoDestroy: true,
            root: 'series',
            fields: ['siries_id', 'siries_name', 'number_of_groups'],
        });

        var userList2 = new Ext.data.JsonStore({
            autoDestroy: true,
        });

        var userList = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getUserList', filter: 'valid'}, // TODO, get user for this
            autoLoad: true,
            autoDestroy: true,
            root: 'users',
            id: 'userid',
            fields: userRecord,
            listeners: {
                load: function(store, records, options ) {
                    userList2.add(records.map( r => r.copy() ));
                },
            },
        });

        var groups_store = new Ext.data.ArrayStore({
            autoDestroy: false,
            storeId: 'edit_group_store',
            idIndex: 0,
            fields: [
               {name: 'number', type: 'int'},
               {name: 'show'},
            ],
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
            p.form.load({params: {action: 'getMatch', match_id: in_match_id}, waitMsg: 'Loading...' });
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
                {name: 'group', type: 'int'},
                {name: 'waive', type: 'bool'},
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
                  displayField: 'siries_name', valueField: 'siries_id', hiddenName: 'siries_id', listeners: {
                      select: function(combo, record, index) {
                          var groups_data = [];
                          for ( var i = 1; i <= record.data.number_of_groups; i++ ) {
                              groups_data.push([i, "第" + i + "组"]);
                          }
                          var edit_group = Ext.getCmp('edit_group');
                          edit_group.getStore().loadData(groups_data);
                          edit_group.setValue(1); // select the 1st group
                      },
                },},
                { fieldLabel: '小组', xtype: 'combo', id: 'edit_group', name: 'group_fake', allowBlank: false, editable: false, forceSelection: true, autoSelect: true,
                    triggerAction: 'all', mode: 'local', store: groups_store, displayField: 'show', valueField: 'number', hiddenName: 'group' },
                { fieldLabel: '比赛日期', xtype: 'datefield', format: 'Y-m-d', name: 'date', allowBlank: false },
                { layout : "column", xtype: 'container', defaults: {layout: 'form'}, items: [
                    { fieldLabel: '', xtype: 'combo', id: 'edituser1combo', name: 'user1_fake', allowBlank: false, editable: true, forceSelection: true, typeAhead: true,
                      triggerAction: 'all', mode: 'local',
                      store: userList,
                      displayField: 'full_name', valueField: 'userid', hiddenName: 'userid1', listeners: {
                          select: function(combo, record, index) {
                              Ext.getCmp('user1_avatar').getEl().dom.src = getAvatar(record.data);
                          },
                          change: function(combo, n, o) {
                              var record = userList.getById(n);
                              if ( !record ) return;
                              Ext.getCmp('user1_avatar').getEl().dom.src = getAvatar(record.data);
                          }
                      },
                    },
                    { xtype: 'box', id: 'user1_avatar', autoEl: {tag: 'img', height: 64, src: 'etc/男.png'} },
                    { xtype: 'box', autoEl: {tag: 'img', height: 64, src: 'etc/versus.png'} },
                    { xtype: 'box', id: 'user2_avatar', autoEl: {tag: 'img', height: 64, src: 'etc/男.png'} },
                    { fieldLabel: '', xtype: 'combo', id: 'edituser2combo', name: 'user2_fake', allowBlank: false, editable: true, forceSelection: true, typeAhead: true,
                      triggerAction: 'all', mode: 'local',
                      store: userList2,
                      displayField: 'full_name', valueField: 'userid', hiddenName: 'userid2', listeners: {
                          select: function(combo, record, index) {
                              Ext.getCmp('user2_avatar').getEl().dom.src = getAvatar(record.data);
                          },
                          change: function(combo, n, o) {
                              var record = userList.getById(n);
                              if ( !record ) return;
                              Ext.getCmp('user2_avatar').getEl().dom.src = getAvatar(record.data);
                          }
                      },
                    },
                ]},
                generateGames(),
                { fieldLabel: '负方弃权', name: 'waive', xtype: 'checkbox', allowBlank: true },
                { fieldLabel: 'comment', name: 'comment', xtype: 'textfield', allowBlank: true },
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
                        params: {action: 'editMatch'},
                        success: function(...args) {results(...args); showGeneralInfo(); showMatches(); win.close();},
                        failure: results,
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

    var showPointList = function(siries_id, siries_name, stage, number_of_groups) {
        var myReader = new Ext.data.JsonReader({
            root:'users',
            id: 'userid'
        }, userRecord );
        var grid;
        var original_records;
        var myds = new Ext.data.Store({
            proxy: new Ext.data.HttpProxy({
                        url: tturl,
                        method: 'POST'
            }),
            baseParams: {action: 'getPointList', siries_id: siries_id, stage: stage},
            autoLoad: true,
            autoDestroy: true,
            reader: myReader,
            listeners : {
                'load': function(store, records) {
                    original_records = records.filter(record => record.data.siries > 0); // the one that in this siries;
                    grid.getSelectionModel().selectRecords(original_records, false);
                    // if ( siries_id ) mycm.setConfig(mycmconfig); // if we need change the config dynamically
                },
            },
            sortInfo: {field: 'point', direction: 'DESC'}
        });
        var mycmconfig = [
            new Ext.grid.RowNumberer(),
            {header: 'ID', width: 50, dataIndex: 'userid', hidden: true},
            // the header below is a special blank character
            {header: '　', width: 0, dataIndex: 'employeeNumber', id: 'avatar', renderer: function(value, metadata, record) {
                var img = getAvatar(record.data);
                // use css to show the avatar as tooltip may reload the image from server and cause delay
                return "<span class='avatar'><img height='14' src='" + img + "'/><span><img height='200' src='" + img + "'/></span></span>";
            }},
            {header: '姓名', width: 100, sortable: true, dataIndex: 'cn_name'},
            {header: '外号', width: 120, sortable: true, dataIndex: 'nick_name'},
            {header: '性别', width: 50, sortable: true, dataIndex: 'gender'},
            {header: '胜', width: 50, sortable: true, dataIndex: 'win'},
            {header: '负', width: 50, sortable: true, dataIndex: 'lose'},
            {header: '胜局', width: 50, sortable: true, dataIndex: 'game_win'},
            {header: '负局', width: 50, sortable: true, dataIndex: 'game_lose'},
            {header: '分数', width: 50, sortable: true, dataIndex: 'point'},
        ];
        var selModel, scorePanel;
        var scoreStore = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getPointHistory'},
            autoLoad: false,
            autoDestroy: true,
            root: 'points',
            id: 'userid',
            fields: ['userid', "userid2", "name1", "name2", "point_before", "point_after", "date", 'siries_name', 'stage', 'group_number'],
            listeners: {
                load: function(store, records, options ) {
                    if ( !records.length ) {
                        msgpanel.msg(store.reader.jsonData.msg);
                        return scorePanel.hide();
                    }
                    var x = [];
                    var y = [];
                    records.forEach( function(record) {
                        x.push(record.data.date);
                        y.push([record.data.point_before, record.data.point_after, record.data.point_before, record.data.point_after, record.data]);
                    });
                    scorePanel.echarts.hideLoading();
                    scorePanel.echarts.setOption({
                        title: { text: options.params.userid + ' 的历史分数', x: 'center' },
                        xAxis: { data: x },
                        yAxis: { scale: true },
                        series: [{
                            type: 'k',
                            data: y
                        }]
                    });
                }
            },
        });
        scorePanel = new Ext.ux.EchartsPanel({
            height: 300,
            id: 'score_panel',
            floating: true,
            option: {
                tooltip: {
                    trigger: 'axis',
                    formatter: function (params) {
                        var r = params[0].data[5]; // original record data are in [5]
                        return r.date + '<br/>' + r.siries_name + ' ' + renderStage(r.stage) + ' 第' + r.group_number + '组<br/>' + r.name1 + " vs. " + r.name2 + "<br/>" +  r.point_before + " => " + r.point_after;
                    },
                },
            },
        });
        if ( siries_id ) {
            selModel = new Ext.grid.CheckboxSelectionModel({ checkOnly : true });
            if ( !number_of_groups ) number_of_groups = 1;
            var group_column = {header: '小组', id: 'group', width: 120, sortable: true, xtype: "radiogroupcolumn", dataIndex : "group", radioValues : [], };
            for ( var i = 1; i <= number_of_groups; i++ ) {
                group_column.radioValues.push(i);
            }
            mycmconfig.forEach( function(element) {
                if ( element.header.match(/胜|负/) ) element.hidden = true;
            });
            mycmconfig.unshift(selModel);
            mycmconfig.push(group_column);
        } else {
            selModel = new Ext.grid.RowSelectionModel();
            selModel.on({ 'selectionchange': { fn: function(sm){
                var current = sm.getSelections();
                if ( current.length != 1 ) return;
                var selectID = current[0].data.userid;
                var clentY = window.event.clientY;
                scorePanel.show();
                scorePanel.setPagePosition(200, clentY>=600 ? 100 : 700);
                scorePanel.echarts.showLoading();
                scoreStore.load({ params: {userid: selectID}});
            }, scope: this, delay: 0 }});
        }
        var mycm = new Ext.grid.ColumnModel(mycmconfig);

        var grid = new Ext.grid.GridPanel(Object.assign({}, grid_default, {
            ds: myds,
            cm: mycm,
            sm: selModel,
            title : '积分概览',
            id: 'pointlist',
            listeners: {
                'rowdblclick': function(g, rowIndex, e) {
                    editUserInfo( g.getStore().getAt(rowIndex).get('userid') );
                },
            },
            viewConfig: {
                forceFit: true,
                getRowClass: function(record, index) {
                    return getClass(record);
                },
            },
        }));

        if ( siries_id ) {
            function checkSubmit() {
                var s = Ext.getCmp('add_user_to_siries_submit');
                if ( !s ) return;
                var current = grid.getSelectionModel().getSelections();
                if ( current.length != original_records.length ) {
                    return s.enable();
                }
                var original_users = new Object;;
                original_records.map( x => original_users[x.data.userid] = 1 );
                for ( var i = current.length - 1; i >= 0; i-- ) {
                    if ( !original_users[current[i].data.userid] ) {
                        return s.enable();
                    } else if ( current[i].modified && current[i].modified.group && current[i].modified.group != current[i].data.group ) {
                        return s.enable();
                    }
                }
                s.disable();
            };
            grid.getSelectionModel().on({ 'selectionchange': { fn: checkSubmit, scope: this, delay: 0 }});
            grid.getStore().on({ 'update': { fn: checkSubmit } });
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
                    text: 'Save', xtype: 'button', id: 'add_user_to_siries_submit', type: 'submit', disabled: true,
                    handler: function(){
                        fp.getForm().submit({
                            params: {action: 'editSeriesUser', siries_id: siries_id, stage: stage, users: grid.getSelectionModel().getSelections().map( x => [x.data.userid, x.data.group ])}, // userid1,2 userid2,3
                            success: function(...args) {results(...args); showSeries(); win.close();},
                            failure: results,
                        });
                    }
                },{
                    text: 'Reload', xtype: 'button', type: 'reset',
                    handler: function() { myds.reload(); },
                },{
                    text: 'Email', xtype: 'button', type: 'submit',
                    handler: function(){
                        var current = grid.getSelectionModel().getSelections();
                        var emails = current.map( x => '"' + x.data.name + '"<' + x.data.email + '>' ).join(',');
                        emails += '?subject=' + siries_name;
                        window.open('mailto:' + emails);
                    }
                }]
            });

            var win = new Ext.Window({
                title: "报名比赛 " + siries_name,
                width: 800,
                height: 1000,
                autoScroll: true,
                modal: true,
                items: [fp]
            });

            win.show();
            win.doLayout();
        } else {
            listpanel.removeAll(true);
            listpanel.add(grid);
            listpanel.add(scorePanel);
            listpanel.doLayout();
        }
    };

    var showSeries = function() {
        var myRecordObj = Ext.data.Record.create([
            {name: 'siries_id', type: 'int', sortDir: 'ASC'},
            {name: 'siries_name'},
            {name: 'links'},
            {name: 'number_of_groups', type: 'int'},
            {name: 'group_outlets', type: 'int'},
            {name: 'top_n', type: 'int'},
            {name: 'stage', type: 'int'},
            {name: 'enroll', type: 'int'},
            {name: 'count', type: 'int'},
            {name: 'start'},
            {name: 'end'},
            {name: 'duration'},
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
            autoDestroy: true,
            reader: myReader,
            sortInfo: {field: 'siries_id', direction: 'ASC'}
        });
        var mycm = new Ext.grid.ColumnModel([
            {header: 'ID', sortable: true, dataIndex: 'siries_id'},
            {header: '名字', width: 600, sortable: true, dataIndex: 'siries_name'},
            {header: '小组数', sortable: true, dataIndex: 'number_of_groups'},
            {header: '出线人数', sortable: true, dataIndex: 'group_outlets'},
            {header: '取前几名', sortable: true, dataIndex: 'top_n'},
            {header: '阶段', width: 100, sortable: true, dataIndex: 'stage', renderer: renderStage},
            {header: '报名人数', sortable: true, dataIndex: 'enroll'},
            {header: '当前阶段人数', sortable: true, dataIndex: 'count'},
            {xtype: 'actioncolumn', header: '报名', items: [{icon: 'etc/enroll.png', tooltip: '编辑系列赛参与人员', handler: function(g, rowIndex) {
                var record = g.getStore().getAt(rowIndex);
                var stage = record.get('stage');
                if ( stage >= 100 ) {
                    Ext.Msg.alert('错误', '系列赛已经结束，不能报名');
                } else {
                    showPointList(record.get('siries_id'), record.get('siries_name'), record.get('stage'), record.get('number_of_groups'));
                }
            }}]},
            {xtype: 'actioncolumn', header: '结果', items: [{icon: 'etc/cup.png', tooltip: '显示比赛结果', handler: function(g, rowIndex) {
                var record = g.getStore().getAt(rowIndex);
                showSeriesMatchGroups(record.get('siries_id'), record.get('siries_name'));
            }}]},
            {header: '开始日期', sortable: true, dataIndex: 'start'},
            {header: '结束日期', sortable: true, dataIndex: 'end'},
            {header: '耗时(天)', sortable: true, dataIndex: 'duration'},
            {header: '链接', width: 300, dataIndex: 'links',
                renderer: function(value) {
                    if ( !value ) {
                        return '';
                    }
                    // [txt](URL)\nURL\n...
                    return value.split("\n").map(function(x) {
                        var groups = x.match(/\[(.*?)\]\((.*?)\)/);
                        var txt = x;
                        var url = x;
                        if ( groups ) {
                            txt = groups[1];
                            url = groups[2];
                        }
                        return "<a class='ttlink' target='_blank' href='" + url + "'>" + txt + '</a>';
                    }). join(' ');
                }
            },
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
                { text:"记录比赛结果", handler: function() { editMatch(); } },
                '-',
            ]
        });
        var grid = new Ext.grid.GridPanel(Object.assign({}, grid_default, {
            ds: myds,
            cm: mycm,
            title : '系列赛',
            id: 'sirieslist',
            tbar: toolbar,
            listeners: {
                'rowdblclick': function(g, rowIndex, e) {
                    editSeries(g.getStore().getAt(rowIndex).get('siries_id'));
                },
            },
        }));

        listpanel.removeAll(true);
        listpanel.add(grid);
        listpanel.doLayout();
    };

    var showMatches = function(id) {
        var userList = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getUserList'},
            autoLoad: true,
            autoDestroy: true,
            root: 'users',
            id: 'userid',
            fields: userRecord,
            listeners: {
                load: function(store, records, options ) {
                    if ( !id ) return;
                    Ext.getCmp('match_filter').setValue( store.getById(id).get('full_name') );
                }
            },
        });
        var myReader = new Ext.data.JsonReader({
            root:'matches',
            id: 'match_id',
            fields: [
                {name: 'match_id', type: 'int'},
                {name: 'game_win', type: 'int'},
                {name: 'game_lose', type: 'int'},
                {name: 'full_name'},
                {name: 'point_ref', type: 'int'},
                {name: 'point_before', type: 'int'},
                {name: 'point_after', type: 'int'},
                {name: 'full_name2'},
                {name: 'point_ref2', type: 'int'},
                {name: 'point_before2', type: 'int'},
                {name: 'point_after2', type: 'int'},
                {name: 'games'},
                {name: 'comment'},
                {name: 'waive', type: 'bool'},
                {name: 'siries_name'},
                {name: 'date'},
                {name: 'stage', type: 'int'},
                {name: 'group_number', type: 'int'},
            ],
        });
        var myds = new Ext.data.GroupingStore({
            proxy: new Ext.data.HttpProxy({
                        url: tturl,
                        method: 'POST'
                   }),
            baseParams: {action: 'getMatches', userid: id},
            autoLoad: true,
            autoDestroy: true,
            reader: myReader,
            sortInfo: {field: 'date', direction: 'DESC'},
            groupField: 'siries_name',
            groupDir: 'DESC',
        });
        var mycm = new Ext.grid.ColumnModel([
            new Ext.grid.RowNumberer(),
            {header: '比赛日期', sortable: true, width: 90, dataIndex: 'date'},
            {header: '选手1', width: 200, sortable: true, dataIndex: 'full_name'},
            {header: '比分', sortable: true, width: 40, renderer: function(value, metaData, record, rowIndex, colIndex, store) {
                return record.get('game_win') + ":" + record.get('game_lose');
            }},
            {header: '选手2', width: 200, sortable: true, dataIndex: 'full_name2'},
            {header: '局分', width: 100, sortable: true, dataIndex: 'games', renderer: function(value, metaData, record) {
                if ( record.get('waive') ) return '弃权';
                return value.map( x => x.win + ":" + x.lose ).join(', ');
            }},
            {header: '积分增减', width: 80, sortable: true, renderer: function(value, metaData, record, rowIndex, colIndex, store) {
                return record.get('point_after') - record.get('point_before');
            }},
            {header: '选手1', width: 100, sortable: true, renderer: function(value, metaData, record, rowIndex, colIndex, store) {
                return "(" + record.get('point_ref') + ") " + record.get('point_before') + " => " + record.get('point_after');
            }},
            {header: '选手2', width: 100, sortable: true, renderer: function(value, metaData, record, rowIndex, colIndex, store) {
                return "(" + record.get('point_ref2') + ") " + record.get('point_before2') + " => " + record.get('point_after2');
            }},
            {header: '赛事', width: 400, sortable: true, dataIndex: 'siries_name'},
            {header: '阶段', width: 80, sortable: true, dataIndex: 'stage', renderer: renderStage},
            {header: '小组', width: 40, sortable: true, dataIndex: 'group_number'},
        ]);

        var toolbar = new Ext.Toolbar({
            items:[
                { text:"记录比赛结果", handler: function() { editMatch(); } },
                '-',
                { text:"我的比赛", handler: function () { showMatches(currentUserID); } },
                '-',
                { text:"所有比赛", handler: function () { showMatches(); } },
                '-',
                { xtype: 'combo', name: 'useridfake', id: 'match_filter', allowBlank: true, editable: true, typeAhead: true,
                  triggerAction: 'all', lazyInit: true, lazyRender: false, mode: 'local', value: id || '所有比赛',
                  store: userList,
                  displayField: 'full_name', valueField: 'userid', listeners: {
                      select: function(combo, record, index) {
                          showMatches(record.data.userid);
                      }
                  },
                },
            ]
        });
        var grid = new Ext.grid.GridPanel(Object.assign({}, grid_default, {
            ds: myds,
            cm: mycm,
            title : '比赛结果',
            id: 'matcheslist',
            tbar: toolbar,
            view: new Ext.grid.GroupingView({
                forceFit: true,
                groupTextTpl: '{text} ({[values.rs.length]} {["场"]})'
            }),
        }));

        listpanel.removeAll(true);
        listpanel.add(grid);
        listpanel.doLayout();
    };

    var showUsers = function() {
        var myds = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getUserList'},
            autoLoad: true,
            autoDestroy: true,
            root: 'users',
            id: 'userid',
            fields: userRecord,
        });
        var mycm = new Ext.grid.ColumnModel({
            defaults: {
                width: 100,
                sortable: true
            },
            columns: [
                new Ext.grid.RowNumberer(),
                {header: 'ID', dataIndex: 'userid'},
                {header: 'Name', dataIndex: 'name'},
                {header: '姓名', dataIndex: 'cn_name'},
                {header: '外号', dataIndex: 'nick_name'},
                {header: '性别', dataIndex: 'gender'},
                {header: '类型', dataIndex: 'logintype',
                    renderer: function(value) {
                        var found = loginTypes.find(function(element) {return element[0] == value;});
                        return found ? found[1] : value;
                    },
                },
                {header: '员工号', dataIndex: 'employeeNumber'},
                {header: '邮件地址', width: 300, dataIndex: 'email'},
                {header: '积分', dataIndex: 'point'},
        ]});

        var toolbar = new Ext.Toolbar({
            items:[
                {
                    text:"添加人员",
                    id:'newUser',
                    handler: function(){ editUserInfo(); }
                },
                '-',
                {
                    text:"检查人员",
                    id:'checkUser',
                    handler: function(){ checkAllUsers(); }
                },
                '-',
            ]
        });
        if ( logintype != 0 ) {
            Ext.getCmp('newUser').disable();
            Ext.getCmp('checkUser').disable();
        }
        var grid = new Ext.grid.GridPanel(Object.assign({}, grid_default, {
            ds: myds,
            cm: mycm,
            title : '所有人员信息',
            listeners: {
                'rowdblclick': function(g, rowIndex, e) {
                    editUserInfo( g.getStore().getAt(rowIndex).get('userid') );
                },
            },
            tbar: toolbar,
            viewConfig: {
                forceFit: true,
                getRowClass: function(record, index) {
                    return getClass(record);
                },
            },
        }));

        listpanel.removeAll(true);
        listpanel.add(grid);
        listpanel.doLayout();
    };

    var showSeriesMatchGroups = function(siries_id, siries_name) {
        var myds = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getSeriesMatchGroups', siries_id: siries_id},
            autoDestroy: true,
            autoLoad: true,
            root: 'groups',
            fields: ['siries_id', 'stage', 'group_number'],
            listeners: {
                load: function(store, records, options ) {
                    records.map( r => showSeriesMatch(siries_id, siries_name, r.get('stage'), r.get('group_number')) );
                    listpanel.doLayout();
                },
            },
        });
    };
    var showSeriesMatch = function(siries_id, siries_name, stage, group_number) {
        var content_id = 'show_series_match_' + siries_id + '_' + stage + '_' + group_number;
        listpanel.remove(content_id);
        var title = siries_name + ' ' + renderStage(stage) + ' 第' + group_number + '组 结果';
        var content;
        var myds = new Ext.data.JsonStore({
            url: tturl,
            method: 'POST',
            baseParams: {action: 'getSeriesMatch', siries_id: siries_id, stage: stage, group_number: group_number},
            autoDestroy: true,
            autoLoad: false,
        });
        if ( stage != 2 ) {
            content = new Ext.ux.DynamicGridPanel({
                id: content_id,
                ds: myds,
                rowNumberer: true,
                title : title,
                autoHeight: true,
                border: false,
                frame: true,
                renders: {
                    renderRatio: function(value, metadata, record) {
                        if ( typeof(value) != 'object' ) {
                            metadata.css = metadata.css +" diagonalFalling";
                            return '';
                        }
                        if ( typeof(value.win) != 'undefined' ) {
                            metadata.css = metadata.css + ( value.win ? " win" : ( value.waive ? " waive" : " lose" ) );
                            // http://developer.51cto.com/art/200907/133445.htm
                            // metadata.cellAttr is for the td, and will be masked for the div inside
                            // metadata.attr is for the div inside the td
                            // return '<span ext:qtip="test">' + value.result + '</span>' for value should also work.
                            metadata.attr = 'ext:qtip="' + ( value.waive ? '弃权' :  value.game ) + '"';
                        }
                        return value.result;
                    },
                    renderScore: function(value, metadata, record) {
                        if ( !value || typeof(value) != 'object' ) {
                            value = { value: 0 };
                        }
                        metadata.attr = 'ext:qtip="胜:' + (value.win || 0) + ', 负:' + (value.lose || 0) + ', 弃权:' + (value.waive || 0) + ', 共:' + (value.total || 0) + '"';
                        return value.value;
                    },
                },
            });
        } else {
            function render_bracket(container, team, score, state) {
                switch(state) {
                    case 'empty-bye':
                    case 'empty-tbd':
                        return;
                    default:
                        container.append("<span class='bracket_team'><img src='" + getAvatar(team, 0) +  "'/> " + team.cn_name + "</span>");
                        return;
                }
            }
            content = new Ext.Panel({
                id: content_id,
                title : title,
                border: true,
                items: [{
                    text: '结果在此',
                    id: content_id + '_bracket',
                },{
                    text: "\u{3000}", // chinese space character
                    id: content_id + '_info',
                }]
            });
            myds.on('load', function(store, records, options ) {
                $('#' + content_id + "_info").addClass('bracket_info');
                $('#' + content_id + "_bracket").bracket({ // replace with bracket view
                    teamWidth: 120,
                    init: store.reader.jsonData.bracket,
                    onMatchHover: function(data, hover) {
                        $('#' + content_id + "_info").text(hover ? data.date + ' ' + data.cn_name + ' vs. ' + data.cn_name2 + ' ' + data.game + ' 积分增减:' + (data.point_after - data.point_before): '\u{3000}');
                    },
                    decorator: {
                        render: render_bracket,
                        edit: function() {},
                    },
                });
            });
            myds.load();
        }

        listpanel.add(content);
    };

    // public space
    return {
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
            msgpanel.msg(r);
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
                html: more,
                items: [{
                    text: '我的信息',
                    handler: function () { editUserInfo(currentUserID); }
                },{
                    text: '我的比赛',
                    handler: function () { showMatches(currentUserID); }
                },{
                    text: '积分概览',
                    handler: function () { showPointList(); }
                },{
                    text: '比赛结果',
                    handler: function () { showMatches(); }
                },{
                    text: '系列赛事',
                    handler: showSeries
                },{
                    text: '所有用户',
                    handler: function () { showUsers(); }
                },{
                    text: '源代码库',
                    handler: function () { window.open('https://github.com/wangvisual/tt', '_blank'); },
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
                collapsed: !debug,
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
                autoScroll: true,
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

            Ext.QuickTips.init();
            logpanel.log("OK.");
            msgpanel.msg("Ready.");
            showGeneralInfo();
            showPointList();
        }
    };
}();

Ext.onReady(TT.app.main_page, TT.app);

