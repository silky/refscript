foo(){
  if (?) { 
    return 0;
  } else {
    return 1;
  }
}

main(){
  new := foo();
  old := foo();
  if (new = 1){
    if (old = 0){
      assert FOO: (1=0);
    };
  };
}