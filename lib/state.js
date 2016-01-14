'use strict';

var _typeof = typeof Symbol === "function" && typeof Symbol.iterator === "symbol" ? function (obj) { return typeof obj; } : function (obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol ? "symbol" : typeof obj; };

var _createClass = function () { function defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } } return function (Constructor, protoProps, staticProps) { if (protoProps) defineProperties(Constructor.prototype, protoProps); if (staticProps) defineProperties(Constructor, staticProps); return Constructor; }; }(); // -----------------------------------------------------------------------------
// --SECTION--  global
// -----------------------------------------------------------------------------

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.gen_key = exports.gen_guid = exports.Accessor = exports.aggregate = exports.wrap = exports.error = exports.ok = exports.result = undefined;

var _arangodb = require('org/arangodb');

var _internal2 = require('internal');

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

// -----------------------------------------------------------------------------
// --SECTION--  state factory
// -----------------------------------------------------------------------------
function create(id, options) {
  function get(key) {
    return void 0;
  }

  function set(key, value) {
    return void 0;
  }

  return { get: get, set: set };
}

// -----------------------------------------------------------------------------
// --SECTION--  classes
// -----------------------------------------------------------------------------

var Accessor = function () {
  function Accessor() {
    _classCallCheck(this, Accessor);
  }

  _createClass(Accessor, [{
    key: 'get',
    value: function get(key) {
      var k = (typeof key === 'undefined' ? 'undefined' : _typeof(key)) === 'object' ? key.key : key;
      return this[k];
    }
  }, {
    key: 'set',
    value: function set(kv, value) {
      var key = undefined;
      if ((typeof kv === 'undefined' ? 'undefined' : _typeof(kv)) === 'object') {
        key = kv.key;
        value = value === void 0 ? kv.value : value;
      } else {
        key = kv;
      }
      if (kv.creatable) {
        this[key] = value;
        return key;
      }
      if (this[key] === void 0) {
        return void 0;
      }
      this[key] = value;
      return key;
    }
  }]);

  return Accessor;
}();

// -----------------------------------------------------------------------------
// --SECTION-- functions
// -----------------------------------------------------------------------------

function wrapCollection(collectionName, options) {
  var collection = _arangodb.db._collection(collectionName);
  var keyName = options.key ? options.key : 'k';
  var valueName = options.value ? options.value : 'v';
  var creatable = options.creatable;

  function get(key) {
    var k = (typeof key === 'undefined' ? 'undefined' : _typeof(key)) === 'object' ? key.key : key;
    var res = collection.firstExample(keyName, k);
    return res === null ? void 0 : res[valueName];
  }

  function set(kv, value) {
    var create = creatable,
        k = {},
        v = {},
        res = undefined;
    if ((typeof kv === 'undefined' ? 'undefined' : _typeof(kv)) === 'object') {
      v[valueName] = value === void 0 ? kv.value : value;
      k[keyName] = kv.key;
      if (kv.creatable) {
        create = true;
      }
    } else {
      k[keyName] = kv;
      v[valueName] = value;
    }

    // delete with risk
    if (v[valueName] === void 0) {
      res = collection.removeByExample(k, void 0, 1);
      if (res === 0) {
        return void 0;
      }
      return k[keyName];
    }

    // no key special, create it.
    // !!! value must be object and has an attribute {keyName}
    if (k[keyName] === void 0 && create) {
      if (v[keyName] === void 0) {
        v[keyName] = gen_key();
      }
      res = collection.save(v);
      return v[keyName];
    }

    // update first
    res = collection.updateByExample(k, v, true, void 0, 1);
    if (res === 0) {
      if (create) {
        // not found, then create
        v[keyName] = k[keyName];
        collection.save(v);
        return v[keyName];
      }
      return void 0;
    }

    return k[keyName];
  }

  return { get: get, set: set };
}

// 128 bits
function gen_guid() {
  return _internal2.internal.genRandomAlphaNumbers(22);
}

//64 bits
function gen_key() {
  return _internal2.internal.genRandomAlphaNumbers(11);
}

function result(sign, output) {
  return { sign: sign, output: output };
}

function ok(output) {
  return result('ok', output);
}

function error(output) {
  return result('error', output);
}

function wrap(object) {
  function get(key) {
    var k = (typeof key === 'undefined' ? 'undefined' : _typeof(key)) === 'object' ? key.key : key;
    return object[k];
  }

  function set(kv, value) {
    var key = undefined;
    if ((typeof kv === 'undefined' ? 'undefined' : _typeof(kv)) === 'object') {
      key = kv.key;
      value = kv.value;
    } else {
      key = kv;
    }

    if (kv.creatable) {
      object[key] = value;
      return key;
    }
    if (object[key] === void 0) {
      return void 0;
    }
    object[key] = value;
    return key;
  }

  return { get: get, set: set };
}

// todo: exceptions handler or never
function aggregate() {
  for (var _len = arguments.length, containers = Array(_len), _key = 0; _key < _len; _key++) {
    containers[_key] = arguments[_key];
  }

  function get(key) {
    var obj = undefined,
        v = undefined;
    var _iteratorNormalCompletion = true;
    var _didIteratorError = false;
    var _iteratorError = undefined;

    try {
      for (var _iterator = containers[Symbol.iterator](), _step; !(_iteratorNormalCompletion = (_step = _iterator.next()).done); _iteratorNormalCompletion = true) {
        obj = _step.value;

        v = obj.get(key);
        if (v !== void 0) {
          return v;
        }
      }
    } catch (err) {
      _didIteratorError = true;
      _iteratorError = err;
    } finally {
      try {
        if (!_iteratorNormalCompletion && _iterator.return) {
          _iterator.return();
        }
      } finally {
        if (_didIteratorError) {
          throw _iteratorError;
        }
      }
    }

    return void 0;
  }
  function set(key, value) {
    var obj = undefined,
        res = undefined;
    var _iteratorNormalCompletion2 = true;
    var _didIteratorError2 = false;
    var _iteratorError2 = undefined;

    try {
      for (var _iterator2 = containers[Symbol.iterator](), _step2; !(_iteratorNormalCompletion2 = (_step2 = _iterator2.next()).done); _iteratorNormalCompletion2 = true) {
        obj = _step2.value;

        res = obj.set(key, value);
        if (res !== void 0) {
          return res;
        }
      }
    } catch (err) {
      _didIteratorError2 = true;
      _iteratorError2 = err;
    } finally {
      try {
        if (!_iteratorNormalCompletion2 && _iterator2.return) {
          _iterator2.return();
        }
      } finally {
        if (_didIteratorError2) {
          throw _iteratorError2;
        }
      }
    }
  }

  return { get: get, set: set };
}

// -----------------------------------------------------------------------------
// --SECTION--  exports
// -----------------------------------------------------------------------------
exports.result = result;
exports.ok = ok;
exports.error = error;
exports.wrap = wrap;
exports.aggregate = aggregate;
exports.Accessor = Accessor;
exports.gen_guid = gen_guid;
exports.gen_key = gen_key;
