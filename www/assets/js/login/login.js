function Login(){
	this.username = '';
	this.password = '';
	
}
Login.prototype ={
	login:function(){
		//登录函数
		//1.检查本地COOKIE中，是否有用户和密码，没有就计算为新加，提问下
		const alert = await this.alertController.create({
		  header: '请确认用户',
		  message: '没有检查到该用户，您是否需要增加这个用户到本机',
		  buttons: [
			{
			  text: '取消',
			  role: 'cancel',
			  cssClass: 'secondary',
			  handler: (blah) => {
				console.log('Confirm Cancel: blah');
			  }
			}, {
			  text: '确定',
			  handler: () => {
				console.log('Confirm Okay');
			  }
			}
		  ]
		});

		await alert.present();
	}
}