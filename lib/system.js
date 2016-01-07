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

// -----------------------------------------------------------------------------
// --SECTION--                                                             actor
// -----------------------------------------------------------------------------
class System extends Sop.Accessor {
  constructor(id, platform) {
    super()
    const systems = platform.get('systems')
    const meta = systems.get(id)
    this._meta = meta
    if (meta.prefix === void 0) {
      this.prefix = platform.get('prefix') + id + '_'
    } else {
      this.prefix = meta.prefix
    }
    if (meta.collections) {
      this.actors = Db._collection(meta.collections.actors)
      this.states = Db._collection(meta.collections.states)
      this.store = Db._collection(meta.collections.store)
    } else if (meta.isolated) {
      this.actors = Db._collection(this.prefix + 'actors')
      this.states = Db._collection(this.prefix + 'states')
      this.store = Db._collection(this.prefix + 'store')
    } else {
      this.actors = platform.get('actors')
      this.states = platform.get('states')
      this.store = platform.get('store')
    }

    const res = this.actions.entry()
    if (res.state) {
      return res.state
    }
  }

  get actions() {
    return { entry: entry, activity: activity, exit: exit }
  }

  get reactions() {
    return { get: get, put: put, post: post, del: del }
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
  return ok()
}

function del(state, req) {
  this.set(req, void 0)
  return ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                           exports
// -----------------------------------------------------------------------------
function create(id, context) {
  const platform = new System(id, context)
  return Sop.wrap(platform)
}
