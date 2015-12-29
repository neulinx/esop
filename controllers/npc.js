/*globals require, applicationContext */

const _ = require('underscore');
const Joi = require('joi');
const Foxx = require('org/arangodb/foxx');
const ArangoError = require('org/arangodb').ArangoError;
const Controller = new Foxx.Controller(applicationContext);

// Platform
import Platform from 'platform'
const Np = new Platform(applicationContext)
const IPlat = Np.get('reactions')

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
  res.json(IPlat.post(req));
}).bodyParam('system')

/** Reads a np.
 *
 * Reads a np.
 */
controller.get('/:id', function (req, res) {
  var id = req.urlParameters.id;
  res.json(npRepo.byId(id).forClient());
})
  .pathParam('id', npIdSchema)
  .errorResponse(ArangoError, 404, 'The np could not be found');

/** Replaces a np.
 *
 * Changes a np. The information has to be in the
 * requestBody.
 */
controller.put('/:id', function (req, res) {
  var id = req.urlParameters.id;
  var np = req.parameters.np;
  res.json(npRepo.replaceById(id, np));
})
  .pathParam('id', npIdSchema)
  .bodyParam('np', {
    description: 'The np you want your old one to be replaced with',
    type: Np
  })
  .errorResponse(ArangoError, 404, 'The np could not be found');

/** Updates a np.
 *
 * Changes a np. The information has to be in the
 * requestBody.
 */
controller.patch('/:id', function (req, res) {
  var id = req.urlParameters.id;
  var patchData = req.parameters.patch;
  res.json(npRepo.updateById(id, patchData));
})
  .pathParam('id', npIdSchema)
  .bodyParam('patch', {
    description: 'The patch data you want your np to be updated with',
    type: joi.object().required()
  })
  .errorResponse(ArangoError, 404, 'The np could not be found');

/** Removes a np.
 *
 * Removes a np.
 */
controller.delete('/:id', function (req, res) {
  var id = req.urlParameters.id;
  npRepo.removeById(id);
  res.json({ success: true });
})
  .pathParam('id', npIdSchema)
  .errorResponse(ArangoError, 404, 'The np could not be found');
