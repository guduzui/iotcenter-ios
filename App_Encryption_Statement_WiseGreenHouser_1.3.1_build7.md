# App Encryption Statement

Document date: 2026-05-01

This document is prepared for App Store Connect export compliance review for the app identified below.

Note:
- This statement is a supporting explanation document for Apple review.
- If Apple specifically requires a French encryption declaration for France distribution, this statement may need to be supplemented with the official French declaration form.

## 1. App Information

- App name: WiseGreenHouser
- Bundle ID: `com.cloudyboots.wisegreenhouser`
- Version: `1.3.1`
- Build: `7`
- Apple ID: `1232239678`
- Developer / company name: Beijing CloudyBoots Technology Co., Ltd
- Chinese company name: 北京云靴科技有限责任公司
- App type: Greenhouse / IoT device control application

## 2. Summary of Encryption Usage

This app contains and uses encryption-related functionality.

The app uses industry-standard cryptographic algorithms embedded in the bundled frontend code for legacy device communication and data handling. The app is not designed, marketed, or distributed as a general-purpose cryptographic product, VPN product, browser product, secure messaging product, or file-encryption product.

The cryptographic functionality is used only as a technical component of the greenhouse / IoT device control workflow, such as:

- device communication payload handling
- device-side or protocol-side legacy command encryption / decryption
- hashing / integrity-related processing
- authentication or session-related data processing

## 3. Encryption Implemented in the App

Based on the bundled application code currently included in this app, the following cryptographic functionality is present:

- DES encryption / decryption
- MD5
- SHA-1
- SHA-256

These functions appear in bundled frontend JavaScript code and are based on publicly known, industry-standard algorithms rather than proprietary unpublished cryptography.

Relevant bundled code reference:
- `/Users/shuaijq/iotcenter_ios/www/7-es5.c1141fdea38344afb0f9.js`

## 4. Non-Proprietary Nature of the Encryption

The app does not implement proprietary or unpublished cryptographic algorithms created by the developer.

To the best of our current technical review of the app package:

- the app uses standard, publicly known cryptographic algorithms
- the app does not include custom, non-standard encryption algorithms
- the app does not provide cryptographic APIs, SDKs, or encryption tools to end users

## 5. Functional Scope

The app is used to control greenhouse / IoT devices and related automation features. Encryption functionality is incidental to the app's operational workflow and is not the app's primary purpose.

The app is not intended for:

- military or defense end use
- classified communications
- end-user file encryption products
- secure messaging platforms
- VPN or network tunneling services
- general-purpose browser functionality

## 6. Data Potentially Processed with Encryption or Hashing

Depending on the user workflow and connected device functions, the app may process:

- user login or session data
- device serial numbers or identifiers
- device control commands
- device status payloads
- configuration data exchanged with IoT devices

## 7. Suggested Answers in App Store Connect

For the current app package, the recommended direction for App Store Connect export compliance questions is:

1. Does your app use encryption?
   - Yes

2. Is the encryption limited only to Apple's operating system-provided encryption?
   - No

3. Does your app use proprietary or non-standard cryptography?
   - No

4. Is the app primarily an encryption product?
   - No

## 8. Additional Note About France Distribution

Apple's App Store Connect documentation states that when an app uses an industry-standard encryption algorithm not provided solely within Apple's operating system, a French encryption declaration may be required if the app is distributed on the App Store in France.

If France is not required as an availability region, removing France from sale territories is the simplest way to avoid being blocked on this additional document requirement.

## 9. Contact Information

Please replace the placeholders below before final submission if Apple requests formal contact details in the uploaded document:

- Contact person: ____________________
- Title: ____________________
- Email: ____________________
- Phone: ____________________
- Company address: ____________________

---

# 中文版说明

文档日期：2026-05-01

本文件用于 App Store Connect 出口合规审核中的加密说明。

说明：

- 本文件是给 Apple 审核使用的辅助说明材料。
- 如果你保留法国区上架，而 Apple 明确要求上传法国加密申报文件，那么本说明仍可能需要配合法国官方申报表一起提交。

## 1. App 基本信息

- App 名称：WiseGreenHouser
- Bundle ID：`com.cloudyboots.wisegreenhouser`
- 版本号：`1.3.1`
- 构建号：`7`
- Apple ID：`1232239678`
- 开发者公司：Beijing CloudyBoots Technology Co., Ltd
- 中文公司名：北京云靴科技有限责任公司
- App 类型：温室 / IoT 设备控制应用

## 2. 加密使用概述

本 App 包含并使用加密相关功能。

当前 App 包内的前端代码中包含行业标准加密算法，用于兼容既有设备通信协议和数据处理流程。本 App 并不是一个通用加密工具，也不是 VPN、浏览器、安全通讯工具或文件加密产品。

这些加密功能仅作为温室 / IoT 控制流程中的技术组成部分使用，例如：

- 设备通信数据处理
- 设备侧或协议侧遗留命令的加解密
- 哈希或完整性校验处理
- 登录、认证或会话相关处理

## 3. App 中实际包含的加密能力

根据当前打包进 App 的代码，本 App 中包含以下加密相关能力：

- DES 加密 / 解密
- MD5
- SHA-1
- SHA-256

这些能力出现在打包后的前端 JavaScript 代码中，属于公开、通用、行业标准算法，并非开发者自定义的未公开算法。

相关代码位置：

- `/Users/shuaijq/iotcenter_ios/www/7-es5.c1141fdea38344afb0f9.js`

## 4. 是否属于自定义加密

本 App 未实现开发者自创的私有加密算法，也未使用未公开的自定义加密协议。

根据当前代码检查结果：

- 使用的是公开、行业标准算法
- 不包含开发者自定义的非标准密码算法
- 不向最终用户提供通用加密能力或加密开发能力

## 5. 功能边界

本 App 的主要用途是温室 / IoT 设备控制与自动化管理。加密仅是实现业务流程时附带使用的技术能力，不是 App 的核心销售目的。

本 App 不属于以下类型：

- 军事或国防用途软件
- 涉密通信软件
- 面向用户的文件加密工具
- 安全通讯平台
- VPN 或网络隧道服务
- 通用浏览器产品

## 6. 可能涉及的加密 / 哈希数据类型

在实际业务流程中，App 可能对以下数据进行加密或哈希相关处理：

- 用户登录或会话数据
- 设备编号或序列号
- 设备控制指令
- 设备状态数据
- IoT 设备配置数据

## 7. App Store Connect 中建议的选择方向

针对当前这个 App 包，建议在 App Store Connect 的出口合规问题中按以下方向填写：

1. 你的 App 是否使用加密？
   - 选 `Yes`

2. 这些加密是否仅限于 Apple 操作系统自带的加密？
   - 选 `No`

3. 你的 App 是否使用私有或非标准加密？
   - 选 `No`

4. 你的 App 是否是以加密功能为核心目的的产品？
   - 选 `No`

## 8. 关于法国区的说明

根据 Apple 的官方说明，如果 App 使用的是“不是仅由 Apple 操作系统提供”的行业标准加密算法，并且 App 要在法国区上架，那么可能需要额外上传法国加密申报文件。

如果你并不需要法国区上架，最简单的办法是把 France 从销售地区中移除。

## 9. 联系信息

如果 Apple 要求你在上传文稿里写正式联系人，请把下面占位信息补全后再提交：

- 联系人：____________________
- 职务：____________________
- 邮箱：____________________
- 电话：____________________
- 公司地址：____________________
