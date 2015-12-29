// -----------------------------------------------------------------------------
// --SECTION--                                                            global
// -----------------------------------------------------------------------------

const _Db = require("org/arangodb").db

const DFL_PREFIX = 'np_'
const DFL_ID = 'np'
const DFL_COLLECTIONS = {
  systems: `${DFL_PREFIX}systems`,
  actors: `${DFL_PREFIX}actors`,
  states: `${DFL_PREFIX}states`,
  data: `${DFL_PREFIX}data`,
}


function result(directive, output, state) {
  return { directive, output, state }
}

function ok(description) {
  return result('ok', { description })
}

function error(description) {
  return result('error', { description })
}

// -----------------------------------------------------------------------------
// --SECTION--                                                             actor
// -----------------------------------------------------------------------------

class Platform {
  constructor(context) {
    const config = {
      id: DFL_ID,
      prefix: DFL_PREFIX,
      collections: DFL_COLLECTIONS,
      manifest: context,
    }
    this._state = Object.assign(config, context.configuration)
    this._collections = this._state.collections
    this._systems = this._collections.systems
    this._actors = this._collections.actors
    this._states = this._collections.states
    this._data = this._collections._data
    
    const res = this.actions.entry()
    if (res.state) return res.state
  }

  // unified accessor, complex key and aggregator suport.
  get(key) {
    const k = (typeof key === 'object') ? key.key : key
    const v = this[k]
    return v === void 0 ? this._state[k] : v
  }

  set(key, value) {
    let k = (typeof key === 'object') ? key.key : key
    if (key.create) {
      this[k] = value
      return k
    }

    if (this[k] === void 0) {
      if (this._state[k] === void 0) {
        return false
      }
      this._state[k] = value
      return k
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
    delete this.actions
    this.actions = api
    return api
  }

  get reactions() {
    const api = {
      get: get.bind(this),
      put: put.bind(this),
      post: post.bind(this),
      del: del.bind(this),
    }
    delete this.reactions
    this.reactions = api
    return api
  }

}

// -----------------------------------------------------------------------------
// --SECTION--                                                         behaviors
// -----------------------------------------------------------------------------

function entry(input) {
  let collections = this.get('collections')
  // ensure collections is created
  Object.values(collections).forEach(col => {
    if (!_Db._collection(col)) {
      _Db._create(col)
    }
  })
  return ok()
}

function exit(input = { teardown: false }) {
  if (input.teardown) {
    let collections = this.get('collections')
    // ensure collections is created
    Object.values(collections).forEach(col => _Db._drop(col))
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
  return this.set(key, value)
}

function post(req) {
  if (req.action = 'create') { return createSystem(req.system) }
    return error('unkonwn parameter')
}

function del(key) {
  return this.set(key, void 0)
}

// -----------------------------------------------------------------------------
// --SECTION--                                                 private functions
// -----------------------------------------------------------------------------

function createSystem(meta) {
  
}

// -----------------------------------------------------------------------------
// --SECTION--                                                           exports
// -----------------------------------------------------------------------------

export default Platform
