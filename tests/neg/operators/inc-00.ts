
/*@ inc :: ({number | 0 < 1 }) => void */
function inc(x){
  var y = x + 1;
  assert(y > 0);
}

