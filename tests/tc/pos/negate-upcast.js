/*@ negate :: (number + boolean) => number + boolean + string */
function negate(x) {
  if (typeof(x) == "number") {
    return 0 - x;
  } else {
    return !x;
  }
}

