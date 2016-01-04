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
const wrap = Sop.wrap

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
  constructor(id, context) {

    const cfg = context.configuration
    this.id = id
    this.prefix = cfg.prefix ? cfg.prefix : DFL_PREFIX
    this.collections = cfg.collections ? cfg.collections : DFL_COLLECTIONS
    this.systems = Db._collection(this.collections.systems)
    this.actors = Db._collection(this.collections.actors)
    this.states = Db._collection(this.collections.states)
    this.store = Db._collection(this.collections.store)

    const res = this.actions.entry()
    if (res.state) {
      return res.state
    }
  }

  get actions() {
    return {entry: entry, activity: activity, exit: exit}
  }

  get reactions() {
    return {get: get, put: put, post: post, del: del}
  }

}

// -----------------------------------------------------------------------------
// --SECTION--                                                         behaviors
// -----------------------------------------------------------------------------

function entry(state, input) {
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

function exit(state, input) {
  if (input.teardown) {
    let collections = state.get('collections')
    // ensure collections is created
    Object.values(collections).forEach(col => Db._drop(col))
  }
  return ok()
}

function activity(state, input) {
  return ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                         reactions
// -----------------------------------------------------------------------------

function get(state, req) {
  const v = state.get(req)
  if (v === void 0) {
    return error('not found')
  }
}

function put(state, req) {
  const key = state.set(req)
  if (key === void 0) {
    return error('failed to update value')
  }
  return result('ok', key)
}

function post(state, req) {
  if (req.action = 'create') {
    return createSystem(req.system)
  }
  return error('unkonwn parameter')
}

function del(state, req) {
  this.set(req, void 0)
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
function create(id, context) {
  const platform = new Platform(id, context)
  return wrap(platform)
}

//export { Platform }
//export default Platform

//exports.Platform = Platform
exports.create = create