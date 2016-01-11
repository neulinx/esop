// -----------------------------------------------------------------------------
// --SECTION--                                                            global
// -----------------------------------------------------------------------------
'use strict'

const Db = require('org/arangodb').db
const Store = require('store')
const Sop = require('sop')

const DFL_PREFIX = 'np_'
const DFL_NAME = 'np'
const DFL_COLLECTIONS = {
  systems: `${DFL_PREFIX}systems`,
  actors: `${DFL_PREFIX}actors`,
  behaviors: `${DFL_PREFIX}behaviors`,
  miscellany: `${DFL_PREFIX}miscellany`,
}

// -----------------------------------------------------------------------------
// --SECTION--                                                             actor
// -----------------------------------------------------------------------------

class Platform extends Sop.Accessor {
  constructor(context) {
    super()

    const cfg = context.configuration
    this.guid = Store.gen_guid()
    this.timestamp = Date.now()
    this.id = cfg.name ? cfg.name : DFL_NAME
    this.prefix = cfg.prefix ? cfg.prefix : DFL_PREFIX

    const cols = cfg.collections ? cfg.collections : DFL_COLLECTIONS
    this.systems = Store.wrap(cols.systems)
    this.actors = Store.wrap(cols.actors)
    this.behaviors = Store.wrap(cols.behaviors)
    this.miscellany = Store.wrap(cols.miscellany)
    this.collections = cols
    this.actions = {
      entry: input => entry(this, input),
      activity: input => activity(this, input),
      exit: input => exit(this, input),
    }
    this.reactions = {
      get: input => get(this, input),
      put: input => put(this, input),
      post: input => post(this, input),
      del: input => del(this, input),
    }

    this.actions.entry()
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
    return Sop.error('failed to update value');
  }
  return Sop.result('ok', key);
}

function post(state, req) {
  if (req.action === 'create') {
    return createSystem(req.system);
  }

  return Sop.error('unkonwn parameter');
}

function del(state, req) {
  state.set(req, void 0)
  return Sop.ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                 private functions
// -----------------------------------------------------------------------------

function createSystem(meta) {
  return Sop.ok()
}

// -----------------------------------------------------------------------------
// --SECTION--                                                           exports
// -----------------------------------------------------------------------------
//export { Platform }
//export default Platform

exports.Platform = Platform