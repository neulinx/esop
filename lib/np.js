/*globals require, applicationContext */

const _db = require("org/arangodb").db

const DFL_MAX_DEPTH = -1
const DFL_PREFIX = 'np_'
const DFL_ID = 'np'
const DFL_COLLECTIONS = {
  systems: `${DFL_PREFIX}systems`,
  actors: `${DFL_PREFIX}actors`,
  states: `${DFL_PREFIX}states`,
  data: `${DFL_PREFIX}data`,
}

function entry(context) {
  const config = {
    id: DFL_ID,
    prefix: DFL_PREFIX,
    collections: DFL_COLLECTIONS,
  }
  
  Object.assign(config, context.configuration)
  
  // ensure collections is created
  Object.values(config).forEach(col => {
    if (!_db._collection(col)) {
      _db._create(col)
    }
  })
  
  const platform = wrap(config)
    
  return platform
}

function wrap(object) {
  // arrow function for const bind.
  return {get: key => object[key], set: (key, value) => object[key] = value}
}