// A bare page, so the test sites need no page descriptor or template.
var portal = require('/lib/xp/portal');

exports.get = function (req) {
  var config = portal.getSiteConfig() || {};
  if (config.csp === 'default-self') {
    portal.csp().defaultSrc("'self'");
  } else if (config.csp === 'strict-dynamic') {
    portal.csp().scriptSrc("'strict-dynamic'").connectSrc("'self'");
  }
  // Report the stored Privatus Analytics site ID, so the test knows which value the processor really saw.
  var site = portal.getSite();
  var siteId = '';
  [].concat((site && site.data && site.data.siteConfig) || []).forEach(function (entry) {
    if (entry.applicationKey === 'com.privatusanalytics.enonic' && entry.config && entry.config.siteId !== undefined) {
      siteId = String(entry.config.siteId);
    }
  });
  return {
    headers: {'X-Fixture-Site-Id': siteId},
    contentType: 'text/html',
    body: '<!DOCTYPE html><html><head><title>Fixture</title></head><body><p>mode=' + req.mode + '</p></body></html>'
  };
};
