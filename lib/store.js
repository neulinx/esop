'use strict'

// -----------------------------------------------------------------------------
// --SECTION-- global
// -----------------------------------------------------------------------------

const Db = require('org/arangodb').db
const Internal = require('internal')

// -----------------------------------------------------------------------------
// --SECTION-- public
// -----------------------------------------------------------------------------
function wrap(collectionName, options) {
  const collection = Db._collection(collectionName)
  const keyName = options.key ? options.key : 'k'
  const valueName = options.value ? options.value : 'v'
  const creatable = options.creatable

  function get(key) {
    const k = (typeof key === 'object') ? key.key : key
    let res = collection.firstExample(keyName, k)
    return res === null ? void 0 : res[valueName]
  }

  function set(kv, value) {
    let create = creatable, k = {}, v = {}, res
    if (typeof kv === 'object') {
      v[valueName] = value === void 0 ? kv.value : value
      k[keyName] = kv.key
      if (kv.creatable) {
        create = true
      }
    } else {
      k[keyName] = kv
      v[valueName] = value
    }
    
    // delete with risk
    if (v[valueName] === void 0) {
      res = collection.removeByExample(k, void 0, 1)
      if (res === 0) {
        return void 0
      }
      return k[keyName]
    }
    
    // no key special, create it.
    // !!! value must be object and has an attribute {keyName}
    if (k[keyName] === void 0 && create) {
      if (v[keyName] === void 0) {
        v[keyName] = gen_key()
      }
      res = collection.save(v)
      return v[keyName]
    }

    // update first
    res = collection.updateByExample(k, v, true, void 0, 1)
    if (res === 0) {
      if (create) {  // not found, then create
        v[keyName] = k[keyName]
        collection.save(v)
        return v[keyName]
      }
      return void 0
    }

    return k[keyName]
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
// --SECTION-- exports
// -----------------------------------------------------------------------------
exports.wrap = wrap

exports.gen_guid = gen_guid
exports.gen_key = gen_key