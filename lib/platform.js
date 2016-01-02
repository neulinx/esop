// -----------------------------------------------------------------------------
// --SECTION--                                                            global
// -----------------------------------------------------------------------------
'use strict'

const Db = require('org/arangodb').db
// import {result, ok, error} from 'sop'
const Sop = require('sop')
const result = Sop.result
const ok = Sop.ok
const error = Sop.error

const DFL_PREFIX = 'np_'
const DFL_ID = 'np'
const DFL_COLLECTIONS = {
  systems: `${DFL_PREFIX}systems`,
  actors: `${DFL_PREFIX}actors`,
  states: `${DFL_PREFIX}states`,
  store: `${DFL_PREFIX}store`,
}

// -----------------------------------------------------------------------------
// --SECTION--                                                             actor
// -----------------------------------------------------------------------------

class Platform {
  constructor(context) {

    const cfg = context.configuration
    this.prefix = cfg.prefix ? cfg.prefix : DFL_PREFIX
    this.collections = cfg.collections ? cfg.collections : DFL_COLLECTIONS
    this.systems = this.collections.systems
    this.actors = this.collections.actors
    this.states = this.collections.states
    this.store = this.collections.store

    const res = this.actions.entry()
    if (res.state) {
      return res.state
    }
  }

  // unified accessor, complex key and aggregator suport.
  get(key) {
    const k = (typeof key === 'object') ? key.key : key
    return this[k]
  }

  set(key, value) {
    let k = (typeof key === 'object') ? key.key : key
    if (key.create) {
      this[k] = value
      return k
    }

    if (this[k] === void 0) {
      return void 0
    }
    this[k] = value
    return k
  }


  get actions() {
    const api = {
      entry: entry.bind(this),
      exit: exit.bind(this),
      activity: activity.bind(this),
    }
    /* delete this.actions
       this.actions = api
    */
    return api
  }

  get reactions() {
    const api = {
      get: get.bind(this),
      put: put.bind(this),
      post: post.bind(this),
      del: del.bind(this),
    }
    /* delete this.reactions
        this.reactions = api
    */
    return api
  }

}

// -----------------------------------------------------------------------------
// --SECTION--                                                         behaviors
// -----------------------------------------------------------------------------

function entry(input) {
  /*  
  let collections = this.get('collections')
  // ensure collections is created
  Object.values(collections).forEach(function (col) {
    if (!Db._collection(col)) {
      Db._create(col)
    }
  })
  */
  return ok()
}

function exit(input) {
  if (input.teardown) {
    let collections = this.get('collections')
    // ensure collections is created
    Object.values(collections).forEach(col => Db._drop(col))
  }
  return ok()
}

function activity(input) {
  return ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                         reactions
// -----------------------------------------------------------------------------

function get(key) {
  const v = this.get(key)
  if (v === void 0) {
    return error('not found')
  }
}

function put(key, value) {
  const k = this.set(key, value)
  if (k === void 0) {
    return error('failed to update value')
  }
  return result('ok', k)
}

function post(req) {
  if (req.action = 'create') { return createSystem(req.system) }
  return error('unkonwn parameter')
}

function del(key) {
  this.set(key, void 0)
  return ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                 private functions
// -----------------------------------------------------------------------------

function createSystem(meta) {

}

// -----------------------------------------------------------------------------
// --SECTION--                                                           exports
// -----------------------------------------------------------------------------
//export { Platform }
//export default Platform

exports.Platform = Platform
