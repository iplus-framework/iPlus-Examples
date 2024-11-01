SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

SET ANSI_PADDING ON
GO

/****** MATERIAL ******/

CREATE TABLE [dbo].[Material](
	[MaterialID] [uniqueidentifier] NOT NULL,
	[MaterialNo] [varchar](30) NOT NULL,
	[MaterialName1] [varchar](40) NOT NULL,
	[XMLConfig] [text] NULL,
	[InsertName] [varchar](5) NOT NULL,
	[InsertDate] [datetime] NOT NULL,
	[UpdateName] [varchar](5) NOT NULL,
	[UpdateDate] [datetime] NOT NULL,
	[DeleteDate] [datetime] NULL,
	[DeleteName] [varchar](5) NULL,
 CONSTRAINT [PK_Material] PRIMARY KEY CLUSTERED 
(
	[MaterialID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO


/****** ORDER ******/

CREATE TABLE [dbo].[InOrder](
	[InOrderID] [uniqueidentifier] NOT NULL,
	[InOrderNo] [varchar](20) NOT NULL,
	[InOrderDate] [datetime] NOT NULL,
	[Comment] [varchar](max) NULL,
	[XMLConfig] [text] NULL,
	[InsertName] [varchar](5) NOT NULL,
	[InsertDate] [datetime] NOT NULL,
	[UpdateName] [varchar](5) NOT NULL,
	[UpdateDate] [datetime] NOT NULL,
 CONSTRAINT [PK_InOrder] PRIMARY KEY CLUSTERED 
(
	[InOrderID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

/****** ORDER-LINE ******/

CREATE TABLE [dbo].[InOrderPos](
	[InOrderPosID] [uniqueidentifier] NOT NULL,
	[InOrderID] [uniqueidentifier] NOT NULL,
	[Sequence] [int] NOT NULL,
	[MaterialID] [uniqueidentifier] NOT NULL,
	[TargetQuantity] [float] NOT NULL,
	[XMLConfig] [text] NULL,
	[InsertName] [varchar](5) NOT NULL,
	[InsertDate] [datetime] NOT NULL,
	[UpdateName] [varchar](5) NOT NULL,
	[UpdateDate] [datetime] NOT NULL,
 CONSTRAINT [PK_InOrderPos] PRIMARY KEY CLUSTERED 
(
	[InOrderPosID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO

SET ANSI_PADDING OFF
GO

ALTER TABLE [dbo].[InOrderPos]  WITH CHECK ADD  CONSTRAINT [FK_InOrderPos_InOrderID] FOREIGN KEY([InOrderID])
REFERENCES [dbo].[InOrder] ([InOrderID])
ON DELETE CASCADE
GO

ALTER TABLE [dbo].[InOrderPos] CHECK CONSTRAINT [FK_InOrderPos_InOrderID]
GO

ALTER TABLE [dbo].[InOrderPos]  WITH CHECK ADD  CONSTRAINT [FK_InOrderPos_MaterialID] FOREIGN KEY([MaterialID])
REFERENCES [dbo].[Material] ([MaterialID])
GO

