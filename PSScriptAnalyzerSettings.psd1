@{
    # 本仓库是交互式安装/运维脚本集合，以下规则与既定风格冲突，豁免均有依据
    Severity     = @('Warning', 'Error')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                          # 安装/运维脚本依赖彩色控制台输出
        'PSAvoidUsingPlainTextForPassword',               # SFTP/WinSCP 工具链（URL、CLI）需要明文密码参数
        'PSAvoidUsingConvertToSecureStringWithPlainText', # 本地账户 API 只接受明文构造 SecureString
        'PSUseShouldProcessForStateChangingFunctions'     # 一次性安装脚本，不提供 -WhatIf
    )
}
