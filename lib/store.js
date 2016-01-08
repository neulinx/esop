'use strict'

// -----------------------------------------------------------------------------
// --SECTION-- global
// -----------------------------------------------------------------------------

const Db = require('org/arangodb').db

// -----------------------------------------------------------------------------
// --SECTION-- public
// -----------------------------------------------------------------------------
function wrap(collectionName, options) {
  const collection = Db._collection(collectionName)
  const keyName = options.key ? options.key : '_key'
  const valueName = options.value
  const firstOnly = options.result === 'multiple' ? false : true
  const creatable = options.creatable

  const fetch = firstOnly ? collection.firstExample : collection.byExample

  function get(key) {
    let res
    if (typeof key === 'object') {
      // return a cursor with method toArray, next, hasNext, skip, limit
      res = fetch(key)
    } else {
      res = fetch(keyName, key)
    }
    return res === null ? void 0 : res
  }

  function set(kv, value) {
    let create = creatable, k = {}, v = {}, res
    if (typeof kv === 'object') {
      v = value === void 0 ? kv.value : value
      k = kv.key
      if (kv.creatable) {
        create = true
      } 
    } else {
      k[keyName] = kv
      if (valueName) {
        v[valueName] = value
      } else {
        v = value
      }
    }
    
    // delete with risk
    if (v === void 0) {
      res = collection.removeByExample(k, void 0, 1)
      if (res === 0) {
        return void 0
      }
      return k[keyName]
    }
    
    // no key special, create it.
    if (k[keyName] === void 0 && create) {
      res = collection.save(v)
      return keyName === '_key' ? res._key : v[keyName] 
    }

    // update first
    res = collection.updateByExample(k, v, void 0, 1)
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
// --SECTION-- exports
// -----------------------------------------------------------------------------
exports.wrap = wrap
