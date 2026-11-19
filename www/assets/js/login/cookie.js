function YxCookie(){
    this.usercookie = {};	
}
YxCookie.prototype ={
    load:function(){
        var cookieArray = document.cookie;
        if ( cookieArray!=null && cookieArray!="" ){
            var arr = cookieArray.split(";");
            for(var i=0;i<arr.length;i++){
                　　var arr1 = arr.split("=");     //将名/值对以“=”分割开
                    this.usercookie[arr1[0]]=this.usercookie[arr1[1]];
            }
        }
    },
    save:function(){

    },
    get:function(_username){
        return this.usercookie[_username];
    }
}