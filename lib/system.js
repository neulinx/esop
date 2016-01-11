// -----------------------------------------------------------------------------
// --SECTION--                                                            global
// -----------------------------------------------------------------------------
'use strict'
const Db = require('org/arangodb').db
const Sop = require('sop')
const Store = require('store')

// -----------------------------------------------------------------------------
// --SECTION--                                                             actor
// -----------------------------------------------------------------------------
class System extends Sop.Accessor {
  constructor(id, platform) {
    super()
    this.guid = Store.gen_guid()
    this.timestamp = Date.now()

    const systems = platform.get('systems')
    const meta = systems.get(id)
    this._meta = meta
    if (meta.prefix === void 0) {
      this.prefix = `${platform.get('prefix') }${id}_`
    } else {
      this.prefix = meta.prefix
    }
    if (meta.collections) {
      this.actors = Store.wrap(meta.collections.actors)
      this.behaviors = Store.wrap(meta.collections.behaviors)
      this.miscellany = Store.wrap(meta.collections.miscellany)
    } else if (meta.isolated) {
      this.actors = Store.wrap(`${this.prefix}actors`)
      this.behaviors = Store.wrap(`${this.prefix}behaviors`)
      this.miscellany = Store.wrap(`${this.prefix}miscellany`)
    } else {
      this.actors = platform.get('actors')
      this.behaviors = platform.get('behaviors')
      this.miscellany = platform.get('miscellany')
    }

    this.actions.entry()
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
  return Sop.ok()
}

function exit(state, input) {
  if (input.teardown) {
    let collections = state.get('collections')
    // ensure collections is created
    Object.values(collections).forEach(col => Db._drop(col))
  }
  return Sop.ok()
}

function activity(state, input) {
  return Sop.ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                         reactions
// -----------------------------------------------------------------------------

function get(state, req) {
  const v = state.get(req)
  if (v === void 0) {
    return Sop.error('not found')
  }
}

function put(state, req) {
  const key = state.set(req)
  if (key === void 0) {
    return Sop.error('failed to update value')
  }
  return Sop.result('ok', key)
}

function post(state, req) {
  return Sop.ok()
}

function del(state, req) {
  this.set(req, void 0)
  return Sop.ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                           exports
// -----------------------------------------------------------------------------
function create(id, context) {
  const platform = new System(id, context)
  return Store.wrap(platform)
}
