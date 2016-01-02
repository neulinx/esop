/*globals require, applicationContext */
'use strict'

const Foxx = require('org/arangodb/foxx');
const Controller = new Foxx.Controller(applicationContext);

// Platform
//import Platform from 'platform'
const Platform = require('platform').Platform
const Np = new Platform(applicationContext)
const Npi = Np.get('reactions')

/** Lists of all systems on the platform.
 *
 * This function simply returns the list of all systems.
 */
// Display greeting message.
Controller.get('/', function (req, res) {
  res.set("Content-Type", "text/plain; charset=utf-8")
  res.body = "Welcome to Neulinx Platform!\n"
})

/** Creates a new system.
 *
 * Creates a new system. The information has to be in the
 * requestBody.
 */
Controller.post('/', function (req, res) {
  res.json(Npi.post(req));
})
