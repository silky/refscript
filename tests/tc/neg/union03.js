/*@ foo3 :: forall A B. (A, B) => (A|number) */
function foo3(x,y) {
  var a = 1;
  if (a > 10) 
    return y;
  return x;
}


