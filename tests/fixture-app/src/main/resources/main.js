// Test fixture: builds one site per test case in the "privatus-test" project each time the app starts.
// scripts/verify-docker.sh fetches these sites and checks the <head>.
var contentLib = require('/lib/xp/content');
var contextLib = require('/lib/xp/context');
var projectLib = require('/lib/xp/project');
var taskLib = require('/lib/xp/task');
var nodeLib = require('/lib/xp/node');

var PROJECT = 'privatus-test';
var APP = 'com.privatusanalytics.enonic';
var FIXTURE = app.name;

var ALL_ON = {moduleEngage: true, moduleAuto: true, moduleVitals: true, moduleClicks: true, moduleAsk: true};

function merge(a, b) {
  var out = {};
  var k;
  for (k in a) { out[k] = a[k]; }
  for (k in b) { out[k] = b[k]; }
  return out;
}

// name -> [Privatus Analytics config, fixture config]
var SITES = {
  'valid': [merge(ALL_ON, {siteId: 'pa_TEST123', automaticallyAddToPage: true}), {}],
  'defaults': [{siteId: 'pa_TEST123'}, {}],
  'some-modules': [{siteId: 'pa_TEST123', moduleEngage: true, moduleAuto: false, moduleVitals: true, moduleClicks: false, moduleAsk: true}, {}],
  'no-modules': [{siteId: 'pa_TEST123', moduleEngage: false, moduleAuto: false, moduleVitals: false, moduleClicks: false, moduleAsk: false}, {}],
  'no-id': [merge(ALL_ON, {}), {}],
  'prefix-only-id': [merge(ALL_ON, {siteId: 'pa_'}), {}],
  'invalid-id': [merge(ALL_ON, {siteId: 'pa_x" onload="alert(1)'}), {}],
  'off': [merge(ALL_ON, {siteId: 'pa_TEST123', automaticallyAddToPage: false}), {}],
  'csp-default': [merge(ALL_ON, {siteId: 'pa_TEST123'}), {csp: 'default-self'}],
  'csp-strict': [merge(ALL_ON, {siteId: 'pa_TEST123'}), {csp: 'strict-dynamic'}],
  // Only for screenshots of the site config form: no fixture app on it.
  'example-site': [merge(ALL_ON, {siteId: 'pa_7Q2K9XH3AB', automaticallyAddToPage: true}), null]
};

function asAdmin(branch, fn) {
  return contextLib.run({
    repository: 'com.enonic.cms.' + PROJECT,
    branch: branch,
    principals: ['role:system.admin'],
    user: {login: 'su', idProvider: 'system'}
  }, fn);
}

function setup() {
  contextLib.run({principals: ['role:system.admin'], user: {login: 'su', idProvider: 'system'}}, function () {
    if (!projectLib.get({id: PROJECT})) {
      projectLib.create({id: PROJECT, displayName: 'Example project', publicRead: true});
      log.info('Fixture: created project ' + PROJECT);
    }
  });

  asAdmin('draft', function () {
    var ids = [];
    Object.keys(SITES).forEach(function (name) {
      var path = '/' + name;
      if (contentLib.exists({key: path})) {
        contentLib.delete({key: path});
      }
      var params = {
        name: name,
        parentPath: '/',
        displayName: name === 'example-site' ? 'Example site' : name,
        contentType: 'portal:site',
        data: {
          siteConfig: [{applicationKey: APP, config: SITES[name][0]}].concat(
            SITES[name][1] === null ? [] : [{applicationKey: FIXTURE, config: SITES[name][1]}]
          )
        }
      };
      var site;
      try {
        site = contentLib.create(params);
        log.info('Fixture: form accepted ' + name);
      } catch (e) {
        var message = String(e);
        if (message.indexOf('ContentDataValidationException') === -1 && message.indexOf('Incorrect site config') === -1) {
          throw e;
        }
        // XP refuses this config, as Content Studio would. Store a valid one, then write the real one straight into
        // the node (the way an imported or older site could hold it), to prove the processor still adds no tag.
        log.info('Fixture: form rejected ' + name + ' (' + message + ')');
        var realConfig = SITES[name][0];
        params.data.siteConfig[0].config = merge(realConfig, {siteId: 'pa_PLACEHOLDER'});
        site = contentLib.create(params);
        var repo = nodeLib.connect({repoId: 'com.enonic.cms.' + PROJECT, branch: 'draft', principals: ['role:system.admin']});
        repo.modify({
          key: site._id,
          editor: function (node) {
            var configs = [].concat(node.data.siteConfig);
            configs.forEach(function (entry) {
              if (entry.applicationKey === APP) {
                entry.config = realConfig;
              }
            });
            node.data.siteConfig = configs;
            return node;
          }
        });
      }
      ids.push(site._id);
      log.info('Fixture: ' + name + ' is ' + site._id);
    });
    ids.forEach(function (id) {
      var result = contentLib.publish({keys: [id], includeDependencies: false});
      log.info('Fixture: publish ' + id + ' ' + JSON.stringify(result));
    });
  });
}

// Both apps must be installed before a site can name them, and the deploy folder installs them in any order,
// so retry for a while.
taskLib.executeFunction({
  description: 'Privatus Analytics fixture setup',
  func: function () {
    for (var attempt = 1; attempt <= 60; attempt++) {
      try {
        setup();
        log.info('Fixture: ready');
        return;
      } catch (e) {
        log.info('Fixture: attempt ' + attempt + ' failed: ' + e);
        taskLib.sleep(2000);
      }
    }
    log.error('Fixture: setup failed');
  }
});
