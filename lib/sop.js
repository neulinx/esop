'use strict'

// -----------------------------------------------------------------------------
// --SECTION--                                                            result
// -----------------------------------------------------------------------------

function result(directive, output, state) {
  return { directive, output, state }
}

function ok(output) {
  return result('ok', output)
}

function error(output) {
  return result('error', output)
}

// -----------------------------------------------------------------------------
// --SECTION--                                                       data object
// -----------------------------------------------------------------------------
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
    } else {
      key = kv
    }
    
    if (kv.create) {
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
// --SECTION--                                                           exports
// -----------------------------------------------------------------------------

/*
export { result, ok, error }
export default result
*/
exports.result = result
exports.ok = ok
exports.error = error
exports.wrap = wrap
exports.aggregate = aggregate