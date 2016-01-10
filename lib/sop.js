'use strict'

const Internal = require('internal')

// -----------------------------------------------------------------------------
// --SECTION--  result
// -----------------------------------------------------------------------------

function result(sign, output) {
  return { sign, output }
}

function ok(output) {
  return result('ok', output)
}

function error(output) {
  return result('error', output)
}

// -----------------------------------------------------------------------------
// --SECTION--  data object
// -----------------------------------------------------------------------------
class Accessor {
  constructor() {
    this.guid = gen_guid()
  }
  get(key) {
    const k = (typeof key === 'object') ? key.key : key
    return this[k]
  }

  set(kv, value) {
    let key
    if (typeof kv === 'object') {
      key = kv.key
      value = (value === void 0 ? kv.value : value)
    }
    else {
      key = kv
    }
    if (kv.creatable) {
      this[key] = value
      return key
    }
    if (this[key] === void 0) {
      return void 0
    }
    this[key] = value
    return key
  }
}

function wrap(object) {
  function get(key) {
    const k = (typeof key === 'object') ? key.key : key
    return object[k]
  }

  function set(kv, value) {
    let key
    if (typeof kv === 'object') {
      key = kv.key
      value = kv.value
    }
    else {
      key = kv
    }

    if (kv.creatable) {
      object[key] = value
      return key
    }
    if (object[key] === void 0) {
      return void 0
    }
    object[key] = value
    return key
  }

  return { get: get, set: set }
}

// todo: exceptions handler or never
function aggregate(...containers) {
  function get(key) {
    let obj, v
    for (obj of containers) {
      v = obj.get(key)
      if (v !== void 0) {
        return v
      }
    }
    return void 0
  }
  function set(key, value) {
    let obj, res
    for (obj of containers) {
      res = obj.set(key, value)
      if (res !== void 0) {
        return res
      }
    }
  }

  return { get: get, set: set }
}

// -----------------------------------------------------------------------------
// --SECTION--  utilities
// -----------------------------------------------------------------------------

// 128 bits
function gen_guid() {
  return Internal.genRandomAlphaNumbers(22);
}

//64 bits
function gen_key() {
  return Internal.genRandomAlphaNumbers(11);
}

// -----------------------------------------------------------------------------
// --SECTION--  exports
// -----------------------------------------------------------------------------

exports.result = result
exports.ok = ok
exports.error = error

exports.wrap = wrap
exports.aggregate = aggregate
exports.Accessor = Accessor

exports.gen_guid = gen_guid
exports.gen_key = gen_key