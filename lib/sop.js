function result(directive, output, state) {
  return { directive, output, state }
}

function ok(output) {
  return result('ok', output)
}

function error(output) {
  return result('error', output)
}

export { result, ok, error }
export default result