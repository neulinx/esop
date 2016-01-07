'use strict'

// -----------------------------------------------------------------------------
// --SECTION-- global
// -----------------------------------------------------------------------------

const Db = require('org/arangodb').db
const Sop = require('sop')

function wrap(collectionName) {
  const col = Db._collection(collectionName)

  function get(key) {
    if (typeof key === 'object') {
      let res = col.firstExample(key)
      return res === null ? void 0 : res
    }
    try {
      return col.document(key)
    }
    catch (e) {
      return void 0
    }
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
// -----------------------------------------------------------------------------
// --SECTION-- exports
// -----------------------------------------------------------------------------
