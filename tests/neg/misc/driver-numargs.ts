/*@ create :: () => number */
function create(){
  return 0;
}

/*@ acquire :: (number) => number */
function acquire(l){
  assert(l === 0);
  return 1;
}

/*@ release :: (number) => number */
function release(l){
  assert(l === 1);
  return 0;
}

/*@ driver :: (number, number, number) => number */ 
function driver(l0, newCount0, oldCount0){
  
  //ensures($result === 1);
  var l        = l0;
  var newCount = newCount0;
  var oldCount = oldCount0;
  
  if (newCount !== oldCount){
    l        = acquire(l0);
    oldCount = newCount0;
    if (0 < newCount){
      l = release(l);
      newCount = newCount - 1;
    } else {
      newCount = newCount;
    }
    l = driver(l, newCount, oldCount);
  };
  return l;
}

/*@ main :: () => { void | true } */
function main() {
  var newCount = pos();
  var oldCount = pos(); 
  var l        = create();
  if (newCount < oldCount) {
    l = driver(l, newCount, oldCount); 
    l = release(l);
  }
}

