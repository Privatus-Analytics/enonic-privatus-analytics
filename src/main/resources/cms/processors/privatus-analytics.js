var portal = require('/lib/xp/portal');

var TRACKER_HOST = 'https://privatusstats.com';
var SCRIPT_URL = TRACKER_HOST + '/js/pa.js';
var SITE_ID_PATTERN = /^pa_[A-Za-z0-9]+$/;

// Each module, in the order the tracker documents them, with the site config field that turns it on.
var MODULES = [
  ['engage', 'moduleEngage'],
  ['auto', 'moduleAuto'],
  ['vitals', 'moduleVitals'],
  ['clicks', 'moduleClicks'],
  ['ask', 'moduleAsk']
];

// pa.js and its modules load from the tracker host, and hits are sent to the same host with fetch or sendBeacon
// (/api/event, /api/surveys). Each entry is a directive followed by its fallbacks.
var FETCH_DIRECTIVES = [
  ['script-src-elem', 'script-src', 'default-src'],
  ['connect-src', 'default-src']
];

exports.responseProcessor = function (req, res) {
  if (req.mode !== 'live') {
    return res;
  }

  var tag = buildTag(portal.getSiteConfig());
  if (tag === null) {
    return res;
  }

  if (!res.pageContributions) {
    res.pageContributions = {};
  }
  res.pageContributions.headEnd = forceArray(res.pageContributions.headEnd).concat(tag);

  return res;
};

/**
 * Builds the script tag for a site config, or returns null when nothing should be added: the automatic tag is
 * turned off, or the site ID is missing or does not look like a site ID.
 */
function buildTag(siteConfig) {
  siteConfig = siteConfig || {};

  if (siteConfig.automaticallyAddToPage === false) {
    return null;
  }

  var siteId = typeof siteConfig.siteId === 'string' ? siteConfig.siteId.trim() : '';
  if (!SITE_ID_PATTERN.test(siteId)) {
    return null;
  }

  var modules = [];
  for (var i = 0; i < MODULES.length; i++) {
    // A field that was never saved counts as ticked, the same as the form default.
    if (siteConfig[MODULES[i][1]] !== false) {
      modules.push(MODULES[i][0]);
    }
  }

  var nonce = allowTrackerInCsp(portal.csp());
  var reportOnlyNonce = allowTrackerInCsp(portal.cspReportOnly());
  if (nonce === undefined) {
    nonce = reportOnlyNonce;
  }

  var attributes = ['defer', 'src="' + SCRIPT_URL + '"'];
  if (nonce !== undefined) {
    attributes.push('nonce="' + escapeHtmlAttribute(nonce) + '"');
  }
  attributes.push('data-site="' + escapeHtmlAttribute(siteId) + '"');
  // With no data-modules attribute the tracker loads engage by default, so an empty list is written out to
  // load none.
  attributes.push('data-modules="' + escapeHtmlAttribute(modules.join(',')) + '"');

  return '<script ' + attributes.join(' ') + '></script>';
}

/**
 * Allows the tracker host in a policy other contributors have declared, extending the directive that governs each
 * kind of request. A kind no directive covers is left alone, since declaring it would allow nothing but the tracker.
 *
 * Returns the request nonce when the script tag needs one, because 'strict-dynamic' makes the browser ignore host
 * sources.
 */
function allowTrackerInCsp(policy) {
  var nonce;
  if (!policy) {
    return nonce;
  }

  FETCH_DIRECTIVES.forEach(function (fallbacks) {
    var governingName = null;
    var sources = null;
    for (var i = 0; i < fallbacks.length; i++) {
      var found = policy.directive(fallbacks[i]);
      if (found !== null && found !== undefined) {
        governingName = fallbacks[i];
        sources = toArray(found);
        break;
      }
    }

    if (governingName === null) {
      return;
    }

    var isScript = fallbacks[0] === 'script-src-elem';
    var isStrictDynamic = isScript && sources.indexOf(portal.CspSource.STRICT_DYNAMIC) !== -1;

    if (isStrictDynamic && governingName === 'default-src') {
      // A nonce can only be wired into a script directive, so give script elements one of their own, with the same
      // sources as default-src. The request nonce is the only nonce a policy can hold, and it is wired in below.
      var withoutNonces = sources.filter(function (source) {
        return source.indexOf("'nonce-") !== 0;
      });
      policy.add.apply(policy, ['script-src-elem'].concat(withoutNonces, [TRACKER_HOST]));
      nonce = policy.nonceScriptSrcElem();
      return;
    }

    if (sources.length === 1 && sources[0] === portal.CspSource.NONE) {
      policy.override(governingName, TRACKER_HOST);
    } else {
      policy.add(governingName, TRACKER_HOST);
    }

    if (isStrictDynamic) {
      nonce = governingName === 'script-src-elem' ? policy.nonceScriptSrcElem() : policy.nonceScriptSrc();
    }
  });

  return nonce;
}

function toArray(value) {
  var result = [];
  if (value === null || value === undefined) {
    return result;
  }
  if (typeof value.length === 'number' && typeof value !== 'string') {
    for (var i = 0; i < value.length; i++) {
      result.push(String(value[i]));
    }
    return result;
  }
  result.push(String(value));
  return result;
}

function forceArray(data) {
  if (data === null || data === undefined) {
    return [];
  }
  return Array.isArray(data) ? data : [data];
}

function escapeHtmlAttribute(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

