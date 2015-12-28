const _ = require('underscore');
const _Joi = require('joi');
const _Foxx = require('org/arangodb/foxx');
const _ArangoError = require('org/arangodb').ArangoError;
const _Np = require('../models/np');
const _Controller = new _Foxx.Controller(applicationContext);

const SystemIdSchema = Joi.string().required()
.description('The name of the system.')
.meta({allowMultiple: false});

var npRepo = new NpRepo(
  applicationContext.collection('np'),
  {model: Np}
);

/** Lists of all np.
 *
 * This function simply returns the list of all Np.
 */
controller.get('/', function (req, res) {
  res.json(_.map(npRepo.all(), function (model) {
    return model.forClient();
  }));
});

/** Creates a new np.
 *
 * Creates a new np. The information has to be in the
 * requestBody.
 */
controller.post('/', function (req, res) {
  var np = req.parameters.np;
  res.json(npRepo.save(np).forClient());
})
.bodyParam('np', {
  description: 'The np you want to create',
  type: Np
});

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
  res.json({success: true});
})
.pathParam('id', npIdSchema)
.errorResponse(ArangoError, 404, 'The np could not be found');
