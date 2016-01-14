/*globals require, applicationContext */

'use strict'

const _foxx = require('org/arangodb/foxx');
const _controller = new _foxx.Controller(applicationContext);

/** Lists of all systems on the platform.
 *
 * This function simply returns the list of all systems.
 */
// Display greeting message.
_controller.get('/', function (req, res) {
  res.set("Content-Type", "text/plain; charset=utf-8")
  res.body = "Welcome to Neulinx Platform!\n"
})
