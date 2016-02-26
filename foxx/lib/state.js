'use strict';

// -----------------------------------------------------------------------------
// --SECTION--  global
// -----------------------------------------------------------------------------

const _db = require('org/arangodb').db;
const _internal = require('internal');

// -----------------------------------------------------------------------------
// --SECTION-- result
// -----------------------------------------------------------------------------
function result(sign, output) {
  return { sign: sign, output: output };
}

function ok(output) {
  return result('ok', output);
}

function error(output) {
  return result('error', output);
}

// -----------------------------------------------------------------------------
// --SECTION-- id generator
// -----------------------------------------------------------------------------
// 128 bits
function gen_guid() {
  return _internal.genRandomAlphaNumbers(22);
}

//64 bits
function gen_key() {
  return _internal.genRandomAlphaNumbers(11);
}

// -----------------------------------------------------------------------------
// --SECTION-- wrapper
// -----------------------------------------------------------------------------
function wrap(object) {
  function get(key) {
    const k = typeof key === 'object' ? key.key : key;
    return object[k];
  }

  function set(kv, value) {
    let key;
    if (typeof kv === 'object') {
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
function aggregate(...containers) {
  function get(key) {
    let obj, v;
    for (obj of containers) {
      v = obj.get(key);
      if (v !== void 0) {
        return v;
      }
    }
    return void 0;
  }
  function set(key, value) {
    let obj, res;
    for (obj of containers) {
      res = obj.set(key, value);
      if (res !== void 0) {
        return res;
      }
    }
  }

  return { get: get, set: set };
}

function wrapCollection(collectionName, options) {
  const collection = _db._collection(collectionName);
  const keyName = options.key ? options.key : 'k';
  const valueName = options.value ? options.value : 'v';
  const creatable = options.creatable;

  function get(key) {
    const k = typeof key === 'object' ? key.key : key;
    let res = collection.firstExample(keyName, k);
    return res === null ? void 0 : res[valueName];
  }

  function set(kv, value) {
    let create = creatable,
        k = {},
        v = {},
        res;
    if (typeof kv === 'object') {
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

// -----------------------------------------------------------------------------
// --SECTION--  state factory
// -----------------------------------------------------------------------------
function create(actor, options) {
  let state = actor;
  if (typeof actor === 'string') {
    if (options.meta) {
      state = options.meta.get(actor);
    } else if (options.collections.meta) {
      options.meta = wrapCollection(options.collections.meta);
    }
  }
  function get(key) {
    return void 0;
  }

  function set(key, value) {
    return void 0;
  }

  return { get: get, set: set };
}

// -----------------------------------------------------------------------------
// --SECTION--  private functions
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// --SECTION--  exports
// -----------------------------------------------------------------------------
exports.result = result;
exports.ok = ok;
exports.error = error;

exports.wrap = wrap;
exports.aggregate = aggregate;

exports.gen_guid = gen_guid;
exports.gen_key = gen_key;