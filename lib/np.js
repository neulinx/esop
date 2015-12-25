/*globals require, applicationContext */

const _db = require("org/arangodb").db

const DFL_MAX_DEPTH = -1
const DFL_PREFIX = 'np_'
const DFL_COLLECTIONS = {
  systems: `${DFL_PREFIX}systems`,
  actors: `${DFL_PREFIX}actors`,
  actions: `${DFL_PREFIX}actions`,
  data: `${DFL_PREFIX}data`,
}

let _state = null

function entry(context) {
  const config = context.configure
  // ensure collections is created
  for (let collection of this.store) {
    if (!Database._collection(collection)) {
      Database._create(collection)
    }
  }
}

class platform {
  constructor(config, options) {
    this.meta = Object.assign({}, config, options)
    this.store = Object.assign({}, DFL_COLLECTIONS, this.meta.collections)
    this.systems = {}
    this.options_get = {}
    this.options_set = { create: false }
  }

  get(key, options = this.options_get) {
    return this.meta[key]
  }

  set(key, value, options = this.options_set) {
    if (!options.create && !this.meta[key]) {
      return false
    }
    this.meta[key] = value
    return true
  }
}



function exit(input = {}) {
  if (input.dropCollections) {
    for (let collection of this.store)
      Database._drop(collection)
  }
}
  
//  activity(input = {}) {}
// reactions
